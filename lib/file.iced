
fs = require 'fs'
blockcrypt  = require './blockcrypt'
log = require './log'
{constants} = require './constants'
base58 = require './base58'
crypto = require 'crypto'
C = require 'constants'
{make_esc} = require './err'

##======================================================================

exports.tmp_filename = tmp_filename = (stem) ->
  ext = base58.encode crypto.rng 8
  [stem, ext].join '.'

##======================================================================

exports.BaseFile = class BaseFile

  #------------------------

  constructor : ({@fd}) ->
    @fd = -1 unless @fd?
    @i = 0

  #------------------------

  close : () ->
    if @fd? >= 0
      fs.close @fd
      @fd = -1
      @i = 0

##======================================================================

exports.Outfile = class Outfile extends BaseFile

  #------------------------

  constructor : ({@target, @mode}) ->
    super({})
    @tmpname = tmp_filename @target
    @renamed = false
    @buf = null
    @i = 0

  #------------------------

  open : (cb) ->
    esc = make_esc cb, "Outfile::open"
    flags = (C.O_WRONLY | C.O_TRUNC | C.O_EXCL | C.O_CREAT)
    await fs.open @tmpname, flags, mode, esc defer @fd
    await fs.realpath @tmpname, esc defer @realpath
    cb null

  #------------------------

  _rename : (cb) ->
    await fs.rename @tmpname, @target, defer err
    if err?
      log.error "Failed to rename temporary file: #{err}"
    else
      @renamed = true
    cb not err?

  #------------------------

  finish : (cb) ->
    @close()
    await @_rename defer()
    await @_clenaup defer()
    cb()

  #------------------------

  _cleanup : (cb) ->
    ok = false
    if not @renamed
      await fs.unlink @tmpname, defer err
      if err?
        log.error "failed to remove temporary file: #{err}"
        ok = false
    cb ok

  #------------------------

  write : (block, cb) ->
    ok = false
    l = block.buf.length
    b = block.buf
    off = block.offset
    await fs.write @fd, b, 0, l, off, defer err, nw
    if err?
      err = new Error "In writing #{@tmpname}@#{off}: #{err}"
    else if nw isnt l 
      err = new Error "Short write in #{@tmpname}: #{nw} != #{l}"
    cb err

##======================================================================

exports.Block = class Block

  constructor : ({@buf, @offset}) ->

  encrypt : (eng) -> new Block { buf : eng.encrypt(@buf), @offset }

##======================================================================

exports.Infile = class Infile extends BaseFile

  constructor : ({@stat, @realpath, @filename, @fd}) ->
    super { @fd }
    @buf = null
    @eof = false

  #------------------------

  size : () -> 
    throw new Error "file is not opened" unless @stat
    @stat.size

  #------------------------

  read : (offset, n, cb) ->
    ret = null
    @buf = new Buffer size unless @buf and @buf.length is size
    await fs.read @fd, @buf, 0, n, offset, defer err, br
    if err? 
      err = new Error "#{@filename}/#{offset}-#{offset+n}: #{err}"
    else if br isnt n 
      err = new Error "Short read: #{br} != #{n}"
    else
      ret = new Block { @buf, offset }
    cb err, ret

  #------------------------

  next : (n, cb) ->
    await @read @i, n, defer err, block
    if block?
      @i += buf.length
      @eof = @i >= @stat.length
    else
      @eof = true
    cb err, block, eof

  #------------------------

  open : (cb) ->
    esc = make_esc cb, "Infile::open"
    await fs.open @filename, flags, esc defer, @fd
    await fs.fstat @fd, esc defer @stat
    await file.realpath esc defer @realpath
    cb null

#==================================================================

concat = (lst) -> Buffer.concat lst

#==================================================================

pack2 = (o) ->
  b1 = purepack.pack o, 'buffer', { byte_arrays : true }
  b0 = purepack.pack b1.length, 'buffer'
  concat [ b0, b1 ]

##======================================================================

uint32 = (i) ->
  b = new Buffer 4
  b.writeUInt32BE i
  b

##======================================================================

class CoderBase

  #--------------

  constructor : ({@keys, @infile, @outfile, @blocksize}) ->
    @blocksize = 1024*1024 unless @blocksize?
    @eof = false
    @err = true
    @ok = false
    @opos = 0

  #-------------------------

  more_to_go : () -> not @eof and not @err

  #--------------

  @premable : () ->
    H = constants.Header
    concat [
      H.FILE_MAGIC
      uint32 H.FILE_VERSION
    ]

##======================================================================

exports.Decoder = class Decoder extends CoderBase

  #--------------

  constructor : (d) ->
    super d

  #---------------------------

  _read_unpack : (cb) ->
    await @infile.next 1, defer b0
    framelen = msgpack_packed_numlen b0.bufer[0]
    if framelen is 0
      log.error "Bad msgpack len header: #{b.inspect()}"
    else

      if framelen > 1
        # Read the rest out...
        await @infile.next (framelen-1), defer b1
        b = concat [b0, b1]
      else
        b = b0

      # We've read the framing in two parts -- the first byte
      # and then the rest
      [err, frame] = purepack.unpack b

      if err?
        log.error "In reading msgpack frame: #{err}"
      else if not (typeof(frame) is 'number')
        log.error "Expected frame as a number: got #{frame}"
      else 
        await @infile.next frame, defer b
        [err, out] = purepack.unpack b
        log.error "In unpacking #{b.inspect()}: #{err}" if err?
    cb out

  #---------------------------

  _read_header : (cb) ->
    p = CoderBase.preamble()
    await @infile.next p.length, defer raw
    if raw? and not bufeq raw.buf, p
      log.error "Premable mismatch/bad magic"
    else
      await @_read_unpack defer obj

  #--------------

##======================================================================

exports.Encoder = class Encoder extends CoderBase

  #--------------

  constructor : (d) ->
    super d

  #--------------
  
  clear_header : (statsize, filesize) ->
    encrypt = @encflag()
    pack2 { statsize, filesize, encrypt, @blocksize }

  #--------------
  
  header : () ->
    estat = @filt pack2 @infile.stat
    concat [
      CoderBase.premable()
      @clear_header estat.length, @infile.stat.size
      estat
    ]

  #--------------

  read : (i, cb) ->
    await @input.next i, defer err, iblock, @eof
    if err?
      @err = true
      log.error err
    else oblock = @filt iblock if oblock?
    cb oblock

  #--------------

  write : (buf, cb) -> 
    await @outfile.write buf, defer err
    if err?
      log.error err
      @err = true
    cb()

  #--------------

  run : (cb) ->
    await @first_block defer()
    bs = @sizer @blocksize
    while @more_to_go()
      await @read bs, defer block
      if block?
        block.offset = @opos
        await @write block, defer()
        @opos += block.buf.length
    cb @ok

  #--------------
  
  first_block : (cb) ->
    hdr = @header()
    if hdr.length > @blocksize
      log.error "First block is too big!! #{hdr.length} > #{@blocksize}"
      @ok = false
    else
      rem_osize = @blocksize - hdr.length
      rem_isize = @sizer rem_osize
      await @read rem_isize, defer rem_block
    if @ok
      buf = concat [ hdr, rem_block.buf ]
      block = new Block { buf, offset : 0 }
      await @write block, defer()
      @opos = @block.length
    cb()

##======================================================================

exports.PlainEncoder = class PlainEncoder extends Encoder

  constructor : ({@keys, @infile, @outfile, @blocksize}) ->
    super()

  infilt : (x) -> x
  sizer : (x) -> x
  encflag : -> 0

##======================================================================

exports.Encryptor = class Encryptor extends Encoder

  constructor : ({@keys, @infile, @outfile, @blocksize}) ->
    super()
    @block_engine = new blockcrypt.Engine @keys

  filt : (x) -> x.encrypt @block_engine
  sizer  : (x) -> blockcrypt.Engine.input_size x
  encflag : -> 1

##======================================================================
