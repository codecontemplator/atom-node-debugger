R = require 'ramda'
path = require 'path'
kill = require 'tree-kill'
Promise = require 'bluebird'
{Client} = require '_debugger'
childprocess = require 'child_process'
{EventEmitter} = require 'events'
Event = require 'geval/event'
logger = require './logger'

log = (msg) -> console.log(msg)

class ProcessManager extends EventEmitter
  constructor: (@atom = atom)->
    super()
    @process = null

  parseEnv: (env) ->
    return null unless env
    key = (s) -> s.split("=")[0]
    value = (s) -> s.split("=")[1]
    result = {}
    result[key(e)] = value(e) for e in env.split(";")
    return result

  start: (file) ->
    @cleanup()
      .then =>
        nodePath = @atom.config.get('node-debugger.nodePath')
        nodeArgs = @atom.config.get('node-debugger.nodeArgs')
        appArgs = @atom.config.get('node-debugger.appArgs')
        port = @atom.config.get('node-debugger.debugPort')
        env = @parseEnv @atom.config.get('node-debugger.env')

        editor = @atom.workspace.getActiveTextEditor()
        appPath = editor.getPath()

        dbgFile = file or appPath
        cwd = path.dirname(dbgFile)

        args = []
        args = args.concat (nodeArgs.split(' ')) if nodeArgs
        args.push "--debug-brk=#{port}"
        args.push dbgFile
        args = args.concat (appArgs.split(' ')) if appArgs

        logger.error 'spawn', {args:args, env:env}
        @process = childprocess.spawn nodePath, args, {
          detached: true
          cwd: cwd
          env: env if env
        }

        @process.stdout.on 'data', (d) ->
          logger.info 'child_process', d.toString()

        @process.stderr.on 'data', (d) ->
          logger.info 'child_process', d.toString()

        @process.stdout.on 'end', () ->
          logger.info 'child_process', 'end out'

        @process.stderr.on 'end', () ->
          logger.info 'child_process', 'end error'

        @emit 'procssCreated', @process

        @process.once 'error', (err) =>
          switch err.code
            when "ENOENT"
              logger.error 'child_process', "ENOENT exit code. Message: #{err.message}"
              atom.notifications.addError(
                "Failed to start debugger.
                Exit code was ENOENT which indicates that the node
                executable could not be found.
                Try specifying an explicit path in your atom config file
                using the node-debugger.nodePath configuration setting."
              )
            else
              logger.error 'child_process', "Exit code #{err.code}. #{err.message}"
          @emit 'processEnd', err

        @process.once 'close', () =>
          logger.info 'child_process', 'close'
          @emit 'processEnd', @process

        @process.once 'disconnect', () =>
          logger.info 'child_process', 'disconnect'
          @emit 'processEnd', @process

        return @process

  cleanup: ->
    self = this
    new Promise (resolve, reject) =>
      return resolve() if not @process?
      if @process.exitCode
        logger.info 'child_process', 'process already exited with code ' + @process.exitCode
        @process = null
        return resolve()

      onProcessEnd = R.once =>
        logger.info 'child_process', 'die'
        @emit 'processEnd', @process
        @process = null
        resolve()

      logger.info 'child_process', 'start killing process'
      kill @process.pid

      @process.once 'disconnect', onProcessEnd
      @process.once 'exit', onProcessEnd
      @process.once 'close', onProcessEnd

class BreakpointManager extends EventEmitter
  constructor: (@debugger) ->
    super()
    log "BreakpointManager.constructor"
    self = this
    @breakpoints = []
    @client = null
    @debugger.on 'connected', ->
      self.client = self.debugger.client
      log "BreakpointManager.connected #{@client}"
      @attachBreakpoint breakpoint for breakpoint in self.breakpoints
    @debugger.on 'disconnected', ->
      log "BreakpointManager.disconnected"
      self.client = null
      breakpoint.id = null for breakpoint in self.breakpoints
    @onAddBreakpointEvent = Event()
    @onRemoveBreakpointEvent = Event()

  toggleBreakpoint: (editor, script, line) ->
    log "BreakpointManager.toggleBreakpoint #{script}, #{line}"
    {breakpoint, index} = @tryFindBreakpoint script, line
    if breakpoint
      @removeBreakpoint breakpoint, index
    else
      @addBreakpoint editor, script, line

  removeBreakpoint: (breakpoint, index) ->
    log "BreakpointManager.removeBreakpoint #{index}"
    @breakpoints.splice index, 1
    breakpoint.marker.destroy()
    @onRemoveBreakpointEvent.broadcast breakpoint
    @detachBreakpoint breakpoint

  addBreakpoint: (editor, script, line) ->
    log "BreakpointManager.addBreakpoint #{script}, #{line}"
    marker = editor.markBufferPosition([line, 0], invalidate: 'never')
    editor.decorateMarker(marker, type: 'line-number', class: 'node-debugger-breakpoint')
    log "BreakpointManager.addBreakpoint marker set"
    breakpoint =
      script: script
      line: line
      marker: marker
      id: null
    @breakpoints.push breakpoint
    log "BreakpointManager.addBreakpoint num breakpoints=#{@breakpoints.length}"
    @onAddBreakpointEvent.broadcast breakpoint
    @attachBreakpoint breakpoint

  attachBreakpoint: (breakpoint) ->
    log "BreakpointManager.attachBreakpoint"
    self = this
    new Promise (resolve, reject) ->
      log "BreakpointManager.attachBreakpoint - Promise"
      return resolve() unless self.client
      log "BreakpointManager.attachBreakpoint - Promise 2"
      self.client.setBreakpoint {
        type: 'script'
        target: breakpoint.script
        line: breakpoint.line-1
        condition: breakpoint.condition
      }, (err, res) ->
        log "BreakpointManager.attachBreakpoint - done"
        return reject(err) if err
        breakpoint.id = res.breakpoint
        resolve(breakpoint)

  detachBreakpoint: (breakpoint) ->
    self = this
    new Promise (resolve, reject) ->
      id = breakpoint.id
      breakpoint.id = null
      return resolve() unless self.client
      return resolve() unless id
      self.client.clearBreakpoint {
        breakpoint: id
      }, (err) ->
        resolve()

  tryFindBreakpoint: (script, line) ->
    { breakpoint: breakpoint, index: i } for breakpoint, i in @breakpoints when breakpoint.script is script and breakpoint.line is line

  getBreakpoints: () -> return @breakpoints

class Debugger extends EventEmitter
  constructor: (@atom, @processManager)->
    super()
    @client = null
    @breakpointManager = new BreakpointManager(this)
    @onBreakEvent = Event()
    @onBreak = @onBreakEvent.listen
    @onAddBreakpoint = @breakpointManager.onAddBreakpointEvent.listen
    @onRemoveBreakpoint = @breakpointManager.onRemoveBreakpointEvent.listen
    @processManager.on 'procssCreated', @start
    @processManager.on 'processEnd', @cleanup

  stopRetrying: ->
    return unless @timeout?
    clearTimeout @timeout

  listBreakpoints: ->
    Promise.resolve([])

  step: (type, count) ->
    self = this
    new Promise (resolve, reject) =>
      @client.step type, count, (err) ->
        return reject(err) if err
        resolve()

  reqContinue: ->
    self = this
    new Promise (resolve, reject) =>
      @client.req {
        command: 'continue'
      }, (err) ->
        return reject(err) if err
        resolve()

  getScriptById: (id) ->
    self = this
    new Promise (resolve, reject) =>
      @client.req {
        command: 'scripts',
        arguments: {
          ids: [id],
          includeSource: true
        }
      }, (err, res) ->
        return reject(err) if err
        resolve(res[0])


  fullTrace: () ->
    new Promise (resolve, reject) =>
      @client.fullTrace (err, res) ->
        return reject(err) if err
        resolve(res)

  start: =>
    logger.info 'debugger', 'start connect to process'
    self = this
    attemptConnectCount = 0
    attemptConnect = ->
      logger.info 'debugger', 'attempt to connect to child process'
      if not self.client?
        logger.info 'debugger', 'client has been cleanup'
        return
      attemptConnectCount++
      self.client.connect(
        self.atom.config.get('node-debugger.debugPort'),
        self.atom.config.get('node-debugger.debugHost')
      )

    onConnectionError = =>
      logger.info 'debugger', "trying to reconnect #{attemptConnectCount}"
      attemptConnectCount++
      @emit 'reconnect', attemptConnectCount
      @timeout = setTimeout =>
        attemptConnect()
      , 500

    @client = new Client()
    @client.once 'ready', @bindEvents

    @client.on 'unhandledResponse', (res) => @emit 'unhandledResponse', res
    @client.on 'break', (res) =>
      @onBreakEvent.broadcast(res.body)
      @emit 'break', res.body
    @client.on 'exception', (res) => @emit 'exception', res.body
    @client.on 'error', onConnectionError
    @client.on 'close', () ->
      logger.info 'client', 'client closed'

    attemptConnect()

  bindEvents: =>
    logger.info 'debugger', 'connected'
    @emit 'connected'
    @client.on 'close', =>
      logger.info 'debugger', 'connection closed'

      @processManager.cleanup()
        .then =>
          @emit 'close'

  lookup: (ref) ->
    new Promise (resolve, reject) =>
      @client.reqLookup [ref], (err, res) ->
        return reject(err) if err
        resolve(res[ref])

  eval: (text) ->
    new Promise (resolve, reject) =>
      @client.req {
        command: 'evaluate'
        arguments: {
          expression: text
        }
      }, (err, result) ->
        return reject(err) if err
        return resolve(result)

  cleanup: =>
    return unless @client?
    @client.destroy()
    @client = null
    @emit 'disconnected'

  isConnected: =>
      return @client?

exports.ProcessManager = ProcessManager
exports.Debugger = Debugger
