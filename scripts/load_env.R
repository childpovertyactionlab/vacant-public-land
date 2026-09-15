# Load .env into the R session for scripts run directly (Rscript) or via
# build_all.sh. Quarto/Rscript do not read .env on their own, so without this
# the documented flow (".env + scripts/build_all.sh") fails at the warehouse
# connect with "no SQL warehouse to connect to".
#
# Shell environment wins: a variable already set in the environment is left
# alone, so `DATABRICKS_TOKEN=... Rscript ...` still overrides the file.
load_dotenv <- function(path = ".env") {
  if (!file.exists(path)) return(invisible(FALSE))
  for (ln in readLines(path, warn = FALSE)) {
    if (grepl("^\\s*(#|$)", ln)) next
    kv <- regmatches(ln, regexec("^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(.*)$", ln))[[1]]
    if (length(kv) != 3L) next
    key <- kv[[2]]
    val <- sub('\\s*#.*$', '', kv[[3]])
    val <- gsub('^\\s*["\']|["\']\\s*$', "", trimws(val))
    if (!nzchar(Sys.getenv(key))) {
      args <- list(val); names(args) <- key
      do.call(Sys.setenv, args)
    }
  }
  invisible(TRUE)
}

load_dotenv()
