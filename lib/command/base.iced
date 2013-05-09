
{AwsWrapper} = require '../aws'
{Config} = require '../config'
log = require '../log'
{PasswordManager} = require '../pw'
base58 = require '../base58'
crypto = require 'crypto'
mycrypto = require '../crypto'
myfs = require '../fs'
fs = require 'fs'
{rmkey} = require '../util'
{add_option_dict} = require './argparse'

#=========================================================================

pick = (args...) ->
  for a in args
    return a if a?
  return null

#=========================================================================

exports.Base = class Base

  #-------------------

  constructor : () ->
    @config = new Config()
    @aws    = new AwsWrapper()
    @pwmgr  = new PasswordManager()

  #-------------------

  set_argv : (a) -> @argv = a

  #-------------------

  @OPTS :
    e :
      alias : 'email'
      help : 'email address, used for salting passwords & other things' 
    s :
      alias : 'salt'
      help : 'salt used as salt and nothing else; overrides emails'
    p : 
      alias : 'password'
      help : 'password used for encryption / decryption'
    P : 
      alias : 'no-prompt'
      action : 'storeTrue',
      help : "Don't prompt for a PW if we were going to"
    c : 
      alias : 'config'
      help : 'a configuration file (rather than ~/.mkb.conf)'

  #-------------------

  need_aws : () -> true

  #-------------------

  init : (cb) ->
    await @config.find @argv.config, defer fc
    if fc 
      await @config.load defer ok
    else if @need_aws()
      log.error "Cannot find config file #{@config.filename}; needed for AWS"
      ok = false

    ok = @aws.init @config.aws            if ok and @need_aws()
    ok = @_init_pwmgr()                   if ok
    cb ok

  #-------------------

  _init_pwmgr : () ->
    pwopts =
      password   : @password()
      no_prompt  : @argv.no_prompt
      salt       : @salt_or_email()

    @pwmgr.init pwopts

  #-------------------

  dynamo  : () -> @aws.dynamo
  glacier : () -> @aws.glacier

  #-------------------

  password : () -> pick @argv.password, @config.password()
  email    : () -> pick @argv.email, @config.email()
  salt     : () -> pick @argv.salt, @config.salt()
  salt_or_email : () -> pick @salt(), @email()

  #----------------

  base_open_input : (fn, cb) ->
    await myfs.open { filename : fn }, defer err, input
    cb err, input

#=========================================================================

exports.CipherBase = class CipherBase extends Base
   
  #-----------------

  OPTS :
    o :
      alias : "output"
      help : "output file to write to"
    r :
      alias : "remove" 
      action : 'storeTrue'
      help : "remove the original file after encryption"
    x :
      alias : "extension"
      help : "encrypted file extension"

  #-----------------

  need_aws : -> false

  #-----------------

  file_extension : () -> @argv.x or @config.file_extension()

  #-----------------

  strip_extension : (fn) ->
    v = fn.split "."
    x = @file_extension()
    l = v.length
    if v[l-1] is x then v[0...(l-1)].join '.'
    else null

  #-----------------

  tmp_filename : (stem) ->
    ext = base58.encode crypto.rng 8
    [stem, ext].join '.'

  #-----------------

  open_output : (cb) ->
    ok = true
    if (ofn = @output_filename())?
      @outfn = ofn
      tmpfn = @tmp_filename @outfn
      await myfs.open { filename : tmpfn, write : true }, defer err, output
      if err?
        log.error "Error opening temp outfile #{tmpfn}: #{err}"
        ok = false
    else 
      output = myfs.stdout()
    cb ok, output

  #-----------------

  # Maybe eventually decryption can do something here...
  patch_file_metadata : (cb) -> cb()

  #-----------------

  cleanup_on_success : (cb) ->
    await fs.rename @output.filename, @outfn, defer err
    ok = true
    if err?
      log.error "Problem in file rename: #{err}"
      ok = false
    if ok and @argv.r
      await fs.unlink @input.filename, defer err
      if err?
        log.error "Error in removing original file #{@input.file}: #{err}"
        ok = false
    if ok
      await @patch_file_metadata defer()
    cb ok
    
  #-----------------

  cleanup_on_failure : (cb) ->
    ok = true
    await fs.unlink @output.tmpfn, defer err
    if err?
      log.warn "cannot remove temporary file #{@output.tmpfn}: #{err}"
      ok = false
    cb ok

  #-----------------

  cleanup : (ok, cb) ->
    if ok 
      await @cleanup_on_success defer ok
    else
      @output?.stream?.close()
      @input?.stream?.close()
      await @cleanup_on_failure defer()
    cb()

  #-----------------

  init : (cb) ->
    await super defer ok
    if ok
      await @base_open_input argv.file[0], defer err, @input
      if err?
        log.error "In opening input file: #{err}"
        ok = false
    if ok
      await @open_output defer ok, @output
    cb ok
  
  #-----------------

  add_subcommand_parser : (scp) ->
    # Ask the child class for the subcommand particulars....
    scd = @subcommand()
    name = rmkey scd, 'name'
    opts = rmkey scd, 'options'

    sub = scp.addParser name, scd
    add_option_dict sub, @OPTS
    add_option_dict sub, opts if opts?

    # There's an optional input filename, since stdin can work too
    sub.addArgument ["file"], { nargs : 1 } 

  #-----------------

  run : (cb) ->
    await @init defer ok

    opened = false

    if ok
      opened = true
      @eng = @make_eng { @pwmgr, @stat }
      await @eng.init defer ok
      if not ok
        log.error "Could not setup keys for encryption/decryption"

    if ok
      @input.stream.pipe(@eng).pipe(@output.stream)
      await @input.stream.once 'end', defer()
      await @output.stream.once 'finish', defer()

    if ok
      [ok, err] = @eng.validate()
      if not ok
        log.error "Final validation error: #{err}"

    await @cleanup ok, defer() if opened
    cb ok

#=========================================================================
