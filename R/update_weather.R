thredds_collapse_one_day <- function(d) {
  setDT(d)
  setnames(d, c("Var1", "Var2"), c("row", "col"))
  d[fhidata::senorge, on = c("row", "col"), location_code := location_code]
  d[fhidata::senorge, on = c("row", "col"), year := year]
  d <- d[!is.na(location_code)]
  d[fhidata::norway_municip_merging,
    on = c(
      "location_code==municip_code_original",
      "year==year"
    ),
    location_code_current := municip_code_current
  ]
  res <- d[, .(
    value = mean(value, na.rm = T)
  ), keyby = .(location_code_current)]

  skeleton <- fhidata::norway_locations_current[, c("municip_code")]
  skeleton[res, on = "municip_code==location_code_current", value := value]
  setnames(skeleton, "municip_code", "location_code")
  setorder(skeleton, location_code)

  skeleton[, value := zoo::na.locf(value)]

  return(skeleton)
}

thredds_get_data <- function(year = NULL, date = NULL) {
  if (is.null(year) & is.null(date)) {
    stop("year AND date cannot be NULL")
  }
  if (!is.null(year) & !is.null(date)) {
    stop("year AND date cannot both be NOT NULL")
  }

  temp_dir <- fhi::temp_dir()
  if (!is.null(year)) {
    file <- glue::glue("seNorge2018_{year}.nc")
    url <- glue::glue("http://thredds.met.no/thredds/fileServer/senorge/seNorge_2018/Archive/{file}")
  } else {
    date <- stringr::str_remove_all(date, "-")
    file <- glue::glue("seNorge2018_{date}.nc")
    url <- glue::glue("http://thredds.met.no/thredds/fileServer/senorge/seNorge_2018/Latest/{file}")
  }
  temp_file <- fs::path(temp_dir, file)

  on.exit(fs::file_delete(temp_file))

  utils::download.file(
    url,
    temp_file
  )

  nc <- ncdf4::nc_open(temp_file)

  dates <- as.Date("1900-01-01") + nc$dim$time$vals
  if (!is.null(year) && year == 2019) {
    dates[1:40] <- as.Date("2019-01-01") + 0:39
  }
  # if(!is.null(year)) dates <- dates[1,]
  # for some weird reason, 'dates' has 2 dates in it when dealing with daily data
  # we only need the first
  # if(!is.null(date)) dates <- dates[1]

  res <- vector("list", length = length(dates))
  for (i in seq_along(res)) {
    tg <- ncdf4::ncvar_get(nc, "tg", start = c(1, 1, i), count = c(nc$dim$X$len, nc$dim$Y$len, 1))
    d <- reshape2::melt(tg)
    temp <- thredds_collapse_one_day(d)
    setnames(temp, "value", "tg")

    rr <- ncdf4::ncvar_get(nc, "rr", start = c(1, 1, i), count = c(nc$dim$X$len, nc$dim$Y$len, 1))
    d <- reshape2::melt(rr)
    prec <- thredds_collapse_one_day(d)
    setnames(prec, "value", "rr")

    res[[i]] <- merge(temp, prec, by = "location_code")
    res[[i]][, date := dates[i]]
  }
  ncdf4::nc_close(nc)

  res <- rbindlist(res)
  setcolorder(res, c("date", "location_code", "tg", "rr"))

  return(res)
}

#' update_weather
#' Updates the weather db tables
#' @export
update_weather <- function() {
  field_types <- c(
    "date" = "DATE",
    "location_code" = "TEXT",
    "tg" = "DOUBLE",
    "rr" = "DOUBLE"
  )

  keys <- c(
    "location_code",
    "date"
  )

  weather <- schema$new(
    db_config = config$db_config,
    db_table = glue::glue("weather"),
    db_field_types = field_types,
    db_load_folder = "/xtmp/",
    keys = keys,
    check_fields_match = TRUE
  )

  weather$db_connect()

  val <- weather$dplyr_tbl() %>%
    dplyr::summarize(last_date = max(date, na.rm = T)) %>%
    dplyr::collect() %>%
    latin1_to_utf8()

  download_dates <- NULL
  download_years <- NULL

  if (is.na(val$last_date)) {
    download_years <- 2006:lubridate::year(lubridate::today())
  } else {
    last_date <- lubridate::today() - 1

    if (val$last_date >= last_date) {
      # do nothing
    } else if (val$last_date >= (last_date - 28)) {
      download_dates <- seq.Date(val$last_date, last_date, by = 1)
      download_dates <- as.character(download_dates)
    } else {
      download_years <- lubridate::year(val$last_date):lubridate::year(lubridate::today())
    }
  }

  if (!is.null(download_dates)) {
    for (i in download_dates) {
      msg(glue::glue("Downloading weather for {i}"))
      d <- thredds_get_data(date = i)
      weather$db_upsert_load_data_infile(d)
    }
  }

  if (!is.null(download_years)) {
    for (i in download_years) {
      msg(glue::glue("Downloading weather for {i}"))
      d <- thredds_get_data(year = i)
      weather$db_upsert_load_data_infile(d)
    }
  }
}

#' get_weather
#' Gets the weather, population weighted at county and national levels
#' @export
get_weather <- function() {
  conn <- get_db_connection()
  use_db(conn, "sykdomspuls")

  if (!DBI::dbExistsTable(conn, "weather")) {
    stop("you need to run update_weather()")
  }

  temp <- dplyr::tbl(conn, "weather") %>%
    dplyr::collect() %>%
    fd::latin1_to_utf8()

  pop <- fhidata::norway_population_current[, .(
    pop = sum(pop)
  ), keyby = .(location_code, year)]

  temp[, year := fhi::isoyear_n(date)]
  temp[pop, on = c("location_code", "year"), pop := pop]
  temp <- temp[!is.na(pop)]

  temp[fhidata::norway_locations_current,
    on = "location_code==municip_code",
    county_code := county_code
  ]
  temp_county <- temp[year >= 2006, .(
    tg = sum(tg * pop, na.rm = T) / sum(pop, na.rm = T),
    rr = sum(rr * pop, na.rm = T) / sum(pop, na.rm = T)
  ), keyby = .(county_code, date)]
  setnames(temp_county, "county_code", "location_code")

  temp_national <- temp[year >= 2006, .(
    tg = sum(tg * pop, na.rm = T) / sum(pop, na.rm = T),
    rr = sum(rr * pop, na.rm = T) / sum(pop, na.rm = T)
  ), keyby = .(date)]
  temp_national[, location_code := "norge"]

  temp[, year := NULL]
  temp[, pop := NULL]
  temp[, county_code := NULL]
  temp <- rbind(temp, temp_county, temp_national)

  temp[, yrwk := fhi::isoyearweek(date)]

  return(temp)
}