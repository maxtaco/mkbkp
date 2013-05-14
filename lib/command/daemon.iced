
{Base} = require './base'
{add_option_dict} = require './argparse'
log = require '../log'
{Server} = require '../server'
{daemon} = require '../util'
fs = require 'fs'

#=========================================================================

exports.Command = class Command extends Base

  OPTS : 
    d :
      alias : 'debug'
      help : 'stay in foreground for debugging'
    f :
      alias : 'foreground'
      help : 'stay in the foreground for production'

  #------------------------------

  add_subcommand_parser : (scp) ->
    opts = 
      help : 'run in daemon mode to coordinate downloads'
    name = 'daemon'
    sub = scp.addParser name, opts
    add_option_dict sub, @OPTS
    return [ name ]

  #------------------------------

  listen : (cb) ->
    await @config.make_tmpdir defer ok
    if ok
      sf = @config.sockfile()
      @server = new Server { @config }
      await @server.listen defer err
      if err?
        log.error "Error listening on #{sf}: #{err}"
        ok = false
      await setTimeout defer(), 1000
    cb ok

  #------------------------------

  init : (cb) ->
    await super defer ok
    await @listen defer ok if ok
    cb ok

  #------------------------------

  daemonize : (cb) ->
    log.info "B"
    daemon [ "daemon", '-f' ]
    log.info "B2"
    await fs.writeFile @config.pidfile(), "#{process.pid}", defer err
    log.info "B3"
    if err? then log.error err
    log.daemonize @config.logfile()
    cb()

  #------------------------------

  run : (cb) ->
    if not @argv.debug and not @argv.foreground
      await @daemonize defer()
    if ok
      await @init defer ok
    if @argv.debug and ok
      await @server.run defer()
    cb ok

#=========================================================================
