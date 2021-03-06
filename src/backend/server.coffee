fs = require 'fs'
path = require 'path'
clc = require 'cli-color'
express = require 'express'
mkdirp = require 'mkdirp'
moment = require 'moment'
io = require 'socket.io'
winston = require 'winston'
{getLocalIPs, getDriveNames, isAllowedIP, getHomeDir} = require './utils'

devmode = false

# Command line arguments.
optimist = require('optimist')
  .options('allowed', default: '', describe: 'List of IP masks that are allowed to access.')
  .options('root', alias: 'r', default: '/', describe: 'Root directory for file sandboxing.')
  .options('port', alias: 'p', default:'5100', describe: 'Port used by the server.')
  .options('pfx', describe: 'Where to store configuration and log files.', default: getHomeDir())
  .options('log', alias: 'l', default: 'info', describe: 'Log level (debug, info, notice, warning, error).')
  .options('nologfile', describe: 'Do not write debug log files.')
  .options('reset', describe: 'Clear configuration file and write new')
  .options('help', describe: 'Show this help message.')
  .options('version', alias: 'v', describe: 'Show application version.')
argv = optimist.argv

# Usage help:
return console.log optimist.help() if argv.help

# Print application version.
if argv.version
  {name, version} = JSON.parse(fs.readFileSync __dirname + '/../../package.json')
  return console.log name.charAt(0).toUpperCase() + name.slice(1) + ' ' + version

# Set root directory.
global.rootDir = argv.root
global.rootDir += '/' unless global.rootDir.length && global.rootDir[global.rootDir.length - 1] == '/'

# Set home directory.
global.homeDir = path.resolve(argv.pfx + '/.styler')
if !fs.existsSync global.homeDir
  mkdirp.sync global.homeDir

# Setup logging.
argv.log = 'info' unless winston.config.syslog.levels[argv.log]?
winston.setLevels winston.config.syslog.levels
unless argv.nologfile
  winston.handleExceptions new winston.transports.File filename: path.join global.homeDir, 'crash.log'
  winston.add winston.transports.File, filename: path.join(global.homeDir, moment().format('YYYYMMDD_HHmmss') + '.log'), level: 'debug', timestamp: (-> (tm = moment()).format('YYYY-MM-DD HH:mm:ss.') + tm.milliseconds()), handleExceptions: true
winston.remove winston.transports.Console
winston.add winston.transports.Console, colorize: true, level: argv.log, handleExceptions: true

# Clear database file if needed.
if argv.reset
  dbpath = path.join global.homeDir, 'db.json'
  fs.unlinkSync dbpath
  winston.info 'Deleted DB file: ' + dbpath

# Setup all IPs that are allowed.
global.allowed = argv.allowed?.split?(',') || []
getLocalIPs (ips) -> global.allowed = global.allowed.concat ips

# Create Express server.
app = express.createServer()
app.configure ->
  app.set 'view options', {layout: false}
  app.set 'views', __dirname + '/../../src/templates'
  app.set 'view engine', 'jade'
app.use express.errorHandler dumpExceptions: true, showStack: true
app.use express.favicon(__dirname + '/../public/img/favicon.ico')
#app.use express.staticCache()

# Authorization middleware.
app.use (req, res, next) ->
  if isAllowedIP global.allowed, req.connection.remoteAddress
    next()
  else
    winston.notice 'Access denied for ' + req.connection.remoteAddress, {request: req.url}
    res.render 'notallowed'

# Always cache fonts and images to avoid flicker
app.use (req, res, next) ->
  if /^\/(css\/istokweb|img)\//.test req.url
    res.header 'Cache-Control', 'maxAge=86400'
  next()

# Provide Jade runtime from NPM module source.
app.get '/vendor/jade.js', (req, res) ->
  res.header 'Cache-Control', 'max-age=86400'
  res.sendfile path.resolve (require.resolve 'jade'), '../runtime.min.js'

app.get '/data/:clientId', (req, res) ->
  {Projects, Clients, Settings} = require "./data"
  res.header 'Content-Type', 'text/javascript'
  res.write 'var __data = '
  data = projects: Projects.toJSON(), clients: Clients.toJSON(), settings: Settings.toJSON()
  projectId = 0
  if client = Clients.find((c) -> c.get('session_id') == parseInt(req.params.clientId))
    projectId = client.get 'project'
  else if project = Projects.get(req.query.clientId)
    projectId = project.id
  if c = (require "./console").consoles[projectId]
    data.states = c.states.toJSON()
  res.end JSON.stringify data

# Provide styler.js with initalization call.
app.get '/styler.js', (req, resp) ->
  fs.readFile __dirname + '/../styler.js', (err, data) ->
    throw err if err
    resp.writeHead 200, 'Content-Type': 'text/javascript'
    resp.write data

    host = req.headers.host
    resp.write "if(!window._styler_loaded){styler.init('#{host}');window._styler_loaded=1;}"
    resp.end()

statics = {}
app.use (req, res, next) ->
  staticObject = if devmode
    statics.dev ?=
      public: (express.static __dirname + "/../public"),
      ace: express.static __dirname + "/../../support/ace/lib"
  else
    statics.build ?=
      public: (express.static __dirname + "/../public", maxAge: 86400000),
      ace: express.static(__dirname + "/../../support/ace/lib", maxAge: 86400000)
  staticObject.public req, res, -> staticObject.ace req, res, next


load_frontpage = (req, res, next) ->
  req.query.clientId = parseInt path.basename req.url
  req.url = '/'
  next()

app.all '/project/:project', load_frontpage
app.all '/edit/:project', load_frontpage
app.all '/[0-9]+', load_frontpage
app.get '/', (req, res) ->
  res.render 'index', devmode: devmode, clientId: req.query.clientId || 0

port = parseInt argv.port


io.server = io.listen app, 'log level': 1
#io.server.enable('browser client minification')
io.server.enable('browser client etag')
#io.server.enable('browser client gzip')
#io.server.set('transports', ['websocket', 'flashsocket', 'htmlfile', 'xhr-polling', 'jsonp-polling'])

msg = "Please open http://localhost:#{port}/ to get started"
cols = 55
console.log '┌' + Array(cols).join('─') + '┐\n│ ' + (msg.replace /http:.*\//, (link) -> clc.bold clc.underline link) + Array(cols - msg.length - 1).join(' ') + '│\n└' + Array(cols).join('─') + '┘'

winston.debug 'Daemon started', port: port, home: global.homeDir, root: global.rootDir, allowed: global.allowed, argv: process.argv

if process.platform != 'win32'
  process.on 'SIGINT', ->
    winston.debug 'Daemon closed with SIGINT'
    process.exit(0)

require './clients'
require './consoles'

{Settings} = require "./data"
setDevSettings = (settings) ->
  devmode = settings.get 'devmode'
  if devmode
    app.disable('view cache')
    winston.debug 'Development mode enabled'
  else
    app.enable('view cache')
    winston.debug 'Development mode disabled'

setTimeout ->
  settings = Settings.at(0);
  settings.bind 'change:devmode', setDevSettings
  setDevSettings settings

  if process.features.nativeapp
    app.on 'listening', ->
      process.emit 'serverload', port

    app.on 'error', (err) ->
      if err.code == 'EADDRINUSE'
        port++
        app.listen port

  app.listen port

, 200
