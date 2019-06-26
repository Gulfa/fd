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


load_data_infile <- function(conn, table, dt, file = "/xtmp/x123.csv") {
  fwrite(dt, file = file, logical01 = T)

  sep <- ","
  eol <- "\n"
  quote <- '"'
  skip <- 0
  header <- T
  path <- normalizePath(file, winslash = "/", mustWork = TRUE)
  sql <- paste0(
    "LOAD DATA INFILE ", DBI::dbQuoteString(conn, path), "\n",
    "INTO TABLE ", DBI::dbQuoteIdentifier(conn, table), "\n",
    "FIELDS TERMINATED BY ", DBI::dbQuoteString(conn, sep), "\n",
    "OPTIONALLY ENCLOSED BY ", DBI::dbQuoteString(conn, quote), "\n",
    "LINES TERMINATED BY ", DBI::dbQuoteString(conn, eol), "\n",
    "IGNORE ", skip + as.integer(header), " LINES"
  )

  DBI::dbExecute(conn, sql)
}

upsert_load_data_infile <- function(conn, table, dt, file = "/xtmp/x123.csv", fields) {
  if (DBI::dbExistsTable(conn, "temporary_table")) DBI::dbRemoveTable(conn, "temporary_table")

  sql <- glue::glue("CREATE TEMPORARY TABLE temporary_table LIKE {table};")
  DBI::dbExecute(conn, sql)

  # TO SPEED UP EFFICIENCY DROP ALL INDEXES HERE

  load_data_infile(conn = conn, "temporary_table", dt, file = file)

  vals_fields <- glue::glue_collapse(fields, sep = ", ")
  vals <- glue::glue("{fields} = VALUES({fields})")
  vals <- glue::glue_collapse(vals, sep = ", ")

  sql <- glue::glue("
    INSERT INTO {table} SELECT {vals_fields} FROM temporary_table
    ON DUPLICATE KEY UPDATE {vals};
    ")
  DBI::dbExecute(conn, sql)

  if (DBI::dbExistsTable(conn, "temporary_table")) DBI::dbRemoveTable(conn, "temporary_table")
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