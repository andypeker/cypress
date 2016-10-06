chalk      = require("chalk")
Promise    = require("bluebird")
inquirer   = require("inquirer")
user       = require("../user")
errors     = require("../errors")
Project    = require("../project")
project    = require("../electron/handlers/project")
Renderer   = require("../electron/handlers/renderer")
automation = require("../electron/handlers/automation")

module.exports = {
  getId: ->
    ## return a random id
    Math.random()

  ensureAndOpenProjectByPath: (id, options) ->
    ## verify we have a project at this path
    ## and if not prompt the user to add this
    ## project. once added then open it.
    {projectPath} = options

    open = =>
      @openProject(id, options)

    Project.exists(projectPath).then (bool) =>
      ## if we have this project then lets
      ## immediately open it!
      return open() if bool

      ## else prompt to add the project
      ## and then open it!
      @promptAddProject(projectPath)
      .then(open)

  promptAddProject: (projectPath) ->
    console.log(
      chalk.yellow("We couldn't find a Cypress project at this path:"),
      chalk.blue(projectPath)
      "\n"
    )

    questions = [{
      name: "add"
      type: "list"
      message: "Would you like to add this project to Cypress?"
      choices: [{
        name: "Yes: add this project and run the tests."
        value: true
      },{
        name: "No:  don't add this project."
        value: false
      }]
    }]

    new Promise (resolve, reject) =>
      inquirer.prompt questions, (answers) =>
        if answers.add
          Project.add(projectPath)
          .then ->
            console.log chalk.green("\nOk great, added the project.\n")
            resolve()
          .catch(reject)
        else
          reject errors.get("PROJECT_DOES_NOT_EXIST")

  openProject: (id, options) ->
    wantsExternalBrowser = !!options.browser

    ## now open the project to boot the server
    ## putting our web client app in headless mode
    ## - NO  display server logs (via morgan)
    ## - YES display reporter results (via mocha reporter)
    project.open(options.projectPath, options, {
      sync:         false
      morgan:       false
      socketId:     id
      report:       true
      isHeadless:   true
      ## TODO: get session into automation.perform
      onAutomationRequest: if wantsExternalBrowser then null else automation.perform

    })
    .catch {portInUse: true}, (err) ->
      errors.throw("PORT_IN_USE_LONG", err.port)

  setProxy: (proxyServer) ->
    session = require("electron").session

    new Promise (resolve) ->
      session.defaultSession.setProxy({
        proxyRules: proxyServer
      }, resolve)

  createRenderer: (url, proxyServer, showGui = false) ->
    @setProxy(proxyServer)
    .then ->
      Renderer.create({
        url:    url
        width:  0
        height: 0
        show:   showGui
        frame:  showGui
        devTools: showGui
        type:   "PROJECT"
      })
      .then (win) ->
        win.webContents.on "new-window", (e, url, frameName, disposition, options) ->
          ## force new windows to automatically open with show: false
          ## this prevents window.open inside of javascript client code
          ## to cause a new BrowserWindow instance to open
          ## https://github.com/cypress-io/cypress/issues/123
          options.show = false

        win.setSize(1280, 720)
        win.center()

  waitForRendererToConnect: (openProject, id) ->
    ## wait up to 10 seconds for the renderer
    ## to connect or die
    @waitForSocketConnection(openProject, id)
    .timeout(10000)
    .catch Promise.TimeoutError, (err) ->
      errors.throw("TESTS_DID_NOT_START")

  waitForSocketConnection: (openProject, id) ->
    new Promise (resolve, reject) ->
      fn = (socketId) ->
        if socketId is id
          ## remove the event listener if we've connected
          openProject.removeListener "socket:connected", fn

          ## resolve the promise
          resolve()

      ## when a socket connects verify this
      ## is the one that matches our id!
      openProject.on "socket:connected", fn

  waitForTestsToFinishRunning: (openProject, gui) ->
    new Promise (resolve, reject) ->
      ## dont ever end if we're in 'gui' debugging mode
      return if gui

      ## when our openProject fires its end event
      ## resolve the promise
      openProject.once "end", resolve

  runTests: (openProject, id, url, proxyServer, gui, browser) ->
    ## we know we're done running headlessly
    ## when the renderer has connected and
    ## finishes running all of the tests.
    ## we're using an event emitter interface
    ## to gracefully handle this in promise land

    getRenderer = =>
      ## if we have a browser then just physically launch it
      if browser
        project.launch(browser, url, null, {proxyServer: proxyServer})
      else
        @createRenderer(url, proxyServer, gui)

    Promise.props({
      connection: @waitForRendererToConnect(openProject, id)
      stats:      @waitForTestsToFinishRunning(openProject, gui)
      renderer:   getRenderer()
    })

  ready: (options = {}) ->
    ready = =>
      id = @getId()

      ## verify this is an added project
      ## and then open it, returning our
      ## project instance
      @ensureAndOpenProjectByPath(id, options)

      .then (openProject) =>
        Promise.all([
          openProject.getConfig(),

          ## either get the url to the all specs
          ## or if we've specificed one make sure
          ## it exists
          openProject.ensureSpecUrl(options.spec)
        ])
        .spread (config, url) =>
          console.log("\nTests should begin momentarily...\n")

          @runTests(openProject, id, url, config.clientUrlDisplay, options.showHeadlessGui, options.browser)
          .get("stats")

    ready()

  run: (options) ->
    app = require("electron").app

    waitForReady = ->
      new Promise (resolve, reject) ->
        app.on "ready", resolve

    Promise.any([
      waitForReady()
      Promise.delay(500)
    ])
    .then =>
      @ready(options)
}