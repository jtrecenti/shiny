#' @noRd
isModuleServer <- function(x) {
  is.function(x) && names(formals(x))[1] == "id"
}

#' Reactive testing for Shiny server functions and modules
#'
#' A way to test the reactive interactions in Shiny applications. Reactive
#' interactions are defined in the server function of applications and in
#' modules.
#' @param app The path to an application or module to test. In addition to
#'   paths, applications may be represented by any object suitable for coercion
#'   to an `appObj` by `as.shiny.appobj`. Application server functions must
#'   include a `session` argument in order to be tested. If `app` is `NULL` or
#'   not supplied, the nearest enclosing directory that is a Shiny app, starting
#'   with the current directory, is used.
#' @param expr Test code containing expectations. The test expression will run
#'   in the server function environment, meaning that the parameters of the
#'   server function (e.g. `input`, `output`, and `session`) will be available
#'   along with any other values created inside of the server function.
#' @param args Additional arguments to pass to the module function.
#'   If `app` is a module, and no `id` argument is provided, one will be
#'   generated and supplied automatically.
#' @return The result of evaluating `expr`.
#' @include mock-session.R
#' @rdname testServer
#' @examples
#' server <- function(id, multiplier = 2, prefix = "I am ") {
#'   moduleServer(id, function(input, output, session) {
#'     myreactive <- reactive({
#'       input$x * multiplier
#'     })
#'     output$txt <- renderText({
#'       paste0(prefix, myreactive())
#'     })
#'   })
#' }
#'
#' testServer(server, args = list(multiplier = 2), {
#'   session$setInputs(x = 1)
#'   # You're also free to use third-party
#'   # testing packages like testthat:
#'   #   expect_equal(myreactive(), 2)
#'   stopifnot(myreactive() == 2)
#'   stopifnot(output$txt == "I am 2")
#'
#'   session$setInputs(x = 2)
#'   stopifnot(myreactive() == 4)
#'   stopifnot(output$txt == "I am 4")
#'   # Any additional arguments, below, are passed along to the module.
#' })
#' @export
testServer <- function(app = NULL, expr, args = list()) {

  require(shiny)

  quosure <- rlang::enquo(expr)
  session <- getDefaultReactiveDomain()

  if (inherits(session, "MockShinySession"))
    stop("Test expressions may not call testServer()")
  if (inherits(session, "session_proxy")
      && inherits(get("parent", envir = session), "MockShinySession"))
    stop("Modules may not call testServer()")

  session <- MockShinySession$new()
  on.exit(if (!session$isClosed()) session$close())

  if (isModuleServer(app)) {
    if (!("id" %in% names(args)))
      args[["id"]] <- session$genId()
    # app is presumed to be a module, and modules may take additional arguments,
    # so splice in any args.
    isolate(
      withReactiveDomain(
        session,
        withr::with_options(list(`shiny.allowoutputreads` = TRUE), {
          rlang::exec(app, !!!args)
        })
      )
    )

    # If app is a module, then we must use both the module function's immediate
    # environment and also its enclosing environment to construct the mask.
    parent_clone <- rlang::env_clone(parent.env(session$env))
    clone <- rlang::env_clone(session$env, parent_clone)
    mask <- rlang::new_data_mask(clone, parent_clone)

    isolate(
      withReactiveDomain(
        session,
        withr::with_options(list(`shiny.allowoutputreads` = TRUE), {
          rlang::eval_tidy(quosure, mask, rlang::caller_env())
        })
      )
    )
  } else {
    if (is.null(app)) {
      app <- findEnclosingApp(".")
    }

    appobj <- as.shiny.appobj(app)
    if (!is.null(appobj$onStart))
      appobj$onStart()
    # Ensure appobj$onStop() is called, and the current directory is restored,
    # regardless of whether invoking the server function is successful.
    tryCatch({
      server <- appobj$serverFuncSource()
      if (! "session" %in% names(formals(server)))
        stop("Tested application server functions must declare input, output, and session arguments.")
      body(server) <- rlang::expr({
        session$setEnv(base::environment())
        !!!body(server)
      })
      if (length(args))
        stop("Arguments were provided to a server function.")
      isolate(
        withReactiveDomain(
          session,
          withr::with_options(list(`shiny.allowoutputreads` = TRUE), {
            server(input = session$input, output = session$output, session = session)
          })
        )
      )
    }, finally = {
      if (!is.null(appobj$onStop))
        appobj$onStop()
    })

    # If app is a server, we use only the server function's immediate
    # environment to construct the mask.
    mask <- rlang::new_data_mask(rlang::env_clone(session$env))

    isolate(
      withReactiveDomain(
        session,
        withr::with_options(list(`shiny.allowoutputreads` = TRUE), {
          rlang::eval_tidy(quosure, mask, rlang::caller_env())
        })
      )
    )
  }

  invisible()
}
