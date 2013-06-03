
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
{Infile, Outfile, Encryptor} = require '../file'
{EscOk} = require 'iced-error'
{E} = require '../err'

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
    c : 
      alias : 'config'
      help : 'a configuration file (rather than ~/.mkb.conf)'
    i : 
      alias : "interactive"
      action : "storeTrue"
      help : "interactive mode"

  #-------------------

  need_aws : () -> true

  #-------------------

  init : (cb) ->

    if @config.loaded
      # The 'init' subcommand will load in an init object that it 
      # invents out of thin air, so no need to read from the FS
      ok = true
    else
      await @config.find @argv.config, defer fc
      if fc  
        await @config.load defer ok
      else if @need_aws()
        log.error "cannot find config file #{@config.filename}; needed for aws"
        ok = false

    ok = @aws.init @config.aws()         if ok and @need_aws()
    ok = @_init_pwmgr()                  if ok
    cb ok

  #-------------------

  init2 : ({infile, outfile, enc}, cb) ->
    esc = new EscOk cb
    await @init esc.check_ok defer(), E.InitError
    if infile
      @infn = @argv.file[0]
      await Infile.open @infn, esc.check_err defer @infile
    if outfile
      await Outfile.open { target : @output_filename() }, esc.check_err defer @outfile
    if enc
      await @pwmgr.derive_keys @is_enc(), esc.check_non_null defer @keys
      @eng = @make_eng { @keys, @infile, @outfile }
    cb true

  #-------------------

  _init_pwmgr : () ->
    pwopts =
      password    : @password()
      salt        : @salt_or_email()
      interactive : @argv.interactive

    @pwmgr.init pwopts

  #-------------------

  dynamo  : () -> @aws.dynamo
  glacier : () -> @aws.glacier

  #-------------------

  password : () -> pick @argv.password, @config.password()
  email    : () -> pick @argv.email, @config.email()
  salt     : () -> pick @argv.salt, @config.salt()
  salt_or_email : () -> pick @salt(), @email()


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
  is_enc : -> false

  #-----------------

  file_extension : () -> @argv.x or @config.file_extension()

  #-----------------

  strip_extension : (fn) -> myfs.strip_extension fn, @file_extension()

  #-----------------

  # Maybe eventually decryption can do something here...
  patch_file_metadata : (cb) -> cb()

  #-----------------

  cleanup : (ok, cb) ->
    await @outfile.finish ok, defer() if @outfile?
    await @infile.finish ok, defer() if @infile?
    cb()

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

    return scd.aliases.concat [ name ]

  #-----------------

  run : (cb) ->
    await @init2 { infile : true, outfile : true, enc : true}, defer ok
    if ok 
      await @eng.run defer err
      if err?
        log.error err
        ok = false
    await @cleanup ok, defer()
    cb ok

#=========================================================================

