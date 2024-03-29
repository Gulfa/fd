#' @importFrom magrittr %>%
#' @export
magrittr::`%>%`

#' use_db
#' @param conn a
#' @param db a
#' @export
use_db <- function(conn, db) {
  a <- DBI::dbGetQuery(conn, glue::glue({
    "SHOW DATABASES LIKE '{db}';"
  }))
  if (nrow(a) == 0) {
    a <- DBI::dbExecute(conn, glue::glue({
      "CREATE DATABASE {db};"
    }))
  }
  a <- DBI::dbExecute(conn, glue::glue({
    "USE {db};"
  }))
}

#' get_field_types
#' @param conn a
#' @param dt a
get_field_types <- function(conn, dt) {
  field_types <- vapply(dt, DBI::dbDataType,
    dbObj = conn,
    FUN.VALUE = character(1)
  )
  return(field_types)
}

random_uuid <- function() {
  x <- uuid::UUIDgenerate(F)
  x <- gsub("-", "", x)
  x <- paste0("a", x)
  x
}

random_file <- function(folder, extension = ".csv") {
  fs::path(folder, paste0(random_uuid(), extension))
}

write_data_infile <- function(dt, file = "/xtmp/x123.csv") {
  fwrite(dt,
    file = file,
    logical01 = T,
    na = "\\N"
  )
}

load_data_infile <- function(conn = NULL, db_config = NULL, table, dt = NULL, file = "/xtmp/x123.csv") {
  if (is.null(conn) & is.null(db_config)) {
    stop("conn and db_config both have error")
  } else if (is.null(conn) & !is.null(db_config)) {
    conn <- get_db_connection(
      driver = db_config$driver,
      server = db_config$server,
      port = db_config$port,
      user = db_config$user,
      password = db_config$password
    )
    use_db(conn, db_config$db)
    on.exit(close(conn))
  }

  if (!is.null(dt)) {
    correct_order <- DBI::dbListFields(conn, "weather")
    setcolorder(dt, correct_order)
    write_data_infile(dt = dt, file = file)
    names_dt <- names(dt)
  } else {
    x <- fread(file, nrows = 1)
    names_dt <- names(x)
  }
  on.exit(fs::file_delete(file), add = T)

  sep <- ","
  eol <- "\n"
  quote <- '"'
  skip <- 0
  header <- T
  path <- normalizePath(file, winslash = "/", mustWork = TRUE)

  sql <- paste0(
    "LOAD DATA INFILE ", DBI::dbQuoteString(conn, path), "\n",
    "INTO TABLE ", DBI::dbQuoteIdentifier(conn, table), "\n",
    "CHARACTER SET utf8", "\n",
    "FIELDS TERMINATED BY ", DBI::dbQuoteString(conn, sep), "\n",
    "OPTIONALLY ENCLOSED BY ", DBI::dbQuoteString(conn, quote), "\n",
    "LINES TERMINATED BY ", DBI::dbQuoteString(conn, eol), "\n",
    "IGNORE ", skip + as.integer(header), " LINES \n",
    "(", paste0(names_dt, collapse = ","), ")"
  )
  DBI::dbExecute(conn, sql)



  return(FALSE)
}

upsert_load_data_infile <- function(conn = NULL, db_config = NULL, table, dt, file = "/xtmp/x123.csv", fields, drop_indexes = NULL) {
  if (is.null(conn) & is.null(db_config)) {
    stop("conn and db_config both have error")
  } else if (is.null(conn) & !is.null(db_config)) {
    conn <- get_db_connection(
      driver = db_config$driver,
      server = db_config$server,
      port = db_config$port,
      user = db_config$user,
      password = db_config$password
    )
    use_db(conn, db_config$db)
    on.exit(close(conn))
  }
  temp_name <- random_uuid()
  on.exit(DBI::dbRemoveTable(conn, temp_name))

  sql <- glue::glue("CREATE TEMPORARY TABLE {temp_name} LIKE {table};")
  DBI::dbExecute(conn, sql)

  # TO SPEED UP EFFICIENCY DROP ALL INDEXES HERE
  if (!is.null(drop_indexes)) {
    for (i in drop_indexes) {
      try(
        DBI::dbExecute(
          conn,
          glue::glue("ALTER TABLE `{temp_name}` DROP INDEX `{i}`")
        ),
        TRUE
      )
    }
  }

  load_data_infile(conn = conn, table = temp_name, dt = dt, file = file)

  vals_fields <- glue::glue_collapse(fields, sep = ", ")
  vals <- glue::glue("{fields} = VALUES({fields})")
  vals <- glue::glue_collapse(vals, sep = ", ")

  sql <- glue::glue("
    INSERT INTO {table} SELECT {vals_fields} FROM {temp_name}
    ON DUPLICATE KEY UPDATE {vals};
    ")
  DBI::dbExecute(conn, sql)

  return(FALSE)
}

create_table <- function(conn, table, fields) {
  fields_new <- fields
  fields_new[fields == "TEXT"] <- "TEXT CHARACTER SET utf8 COLLATE utf8_unicode_ci"
  sql <- DBI::sqlCreateTable(conn, table, fields_new,
    row.names = F, temporary = F
  )
  DBI::dbExecute(conn, sql)
}

drop_all_rows <- function(conn, table) {
  a <- DBI::dbExecute(conn, glue::glue({
    "DELETE FROM {table};"
  }))
}

add_constraint <- function(conn, table, keys) {
  primary_keys <- glue::glue_collapse(keys, sep = ", ")
  sql <- glue::glue("
          ALTER table {table}
          ADD CONSTRAINT X_CONSTRAINT_X PRIMARY KEY ({primary_keys});")
  a <- DBI::dbExecute(conn, sql)
  # DBI::dbExecute(conn, "SHOW INDEX FROM x");
}

#' get_db_connection
#' @param driver driver
#' @param server server
#' @param port port
#' @param user user
#' @param password password
#' @export get_db_connection
get_db_connection <- function(
                              driver = config$db_config$driver,
                              server = config$db_config$server,
                              port = config$db_config$port,
                              user = config$db_config$user,
                              password = config$db_config$password) {
  return(DBI::dbConnect(odbc::odbc(),
    driver = driver,
    server = server,
    port = port,
    user = user,
    password = password,
    encoding = "utf8"
  ))
}

#' tbl
#' @param table table
#' @param db db
#' @export
tbl <- function(table, db = "sykdomspuls") {
  if (is.null(connections[[db]])) {
    connections[[db]] <- get_db_connection()
    use_db(connections[[db]], db)
  }
  return(dplyr::tbl(connections[[db]], table))
}

#' list_tables
#' @param db db
#' @export
list_tables <- function(db = "sykdomspuls") {
  if (is.null(connections[[db]])) {
    connections[[db]] <- get_db_connection()
    use_db(connections[[db]], db)
  }
  return(DBI::dbListTables(connections[[db]]))
}


#' drop_table
#' @param table table
#' @param db db
#' @export
drop_table <- function(table, db = "sykdomspuls") {
  if (is.null(connections[[db]])) {
    connections[[db]] <- get_db_connection()
    use_db(connections[[db]], db)
  }
  return(DBI::dbRemoveTable(connections[[db]], name = table))
}
