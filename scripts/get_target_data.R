#' Build DMA-PRIME Model Challenge target data from CDC NHSN and NSSP
#'
#' Run every Wednesday (see .github/workflows/update-target-data.yaml).
#'
#' Produces, from the hub root:
#'
#'   auxiliary-data/nhsn-raw-data/latest.parquet  as-is NHSN pull (no cleaning)
#'   auxiliary-data/nssp-raw-data/latest.parquet  as-is NSSP pull (no cleaning)
#'   target-data/time-series.parquet              vintaged truth, one as_of per run
#'   target-data/oracle-output.parquet            latest-available scoring truth
#'
#' Targets produced (3 pathogens x 2 families = 6):
#'   wk inc {covid,flu,rsv} hosp            counts, from NHSN
#'   wk inc {covid,flu,rsv} prop ed visits  decimal proportions, from NSSP
#'
#' UNITS: NSSP publishes ED visits as a percentage (e.g. 2.31 meaning 2.31%).
#' Following CovidHub and FluSight, this hub stores and scores them as a decimal
#' proportion (0.0231). The /100 conversion happens here and nowhere else.
#'
#' VINTAGES: each run appends one `as_of` snapshot containing the full observed
#' history as it stood that Wednesday. Re-running on the same date replaces that
#' snapshot rather than duplicating it, so the script is idempotent.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(arrow)
})

options(timeout = 1200)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## Socrata dataset identifiers on data.cdc.gov
NHSN_FINAL_ID <- "ua7e-t2fy"  # Weekly HRD Metrics by Jurisdiction (published Fri)
NHSN_PRELIM_ID <- "mpgq-jmmr" # ...same, Preliminary               (published Wed)
NSSP_ID <- "rdmq-nq56"        # NSSP ED Visit Trajectories          (published Fri)

## Where to get NSSP from.
##   "covidhub" - CDCgov/covid19-forecast-hub's Wednesday mirror of the same
##                dataset (default; one week fresher than CDC's own API, and
##                more reliably accessible from automated workflows)
##   "cdc"      - data.cdc.gov Socrata API (self-contained; refreshed Fridays,
##                so a Wednesday run sees data through the Saturday ~11 days
##                prior; may be subject to connectivity issues)
NSSP_SOURCE <- Sys.getenv("NSSP_SOURCE", "covidhub")
NSSP_COVIDHUB_URL <- paste0(
  "https://raw.githubusercontent.com/CDCgov/covid19-forecast-hub/",
  "main/auxiliary-data/nssp-raw-data/latest.parquet"
)

## Optional Socrata app token (higher rate limits). Not required.
SOCRATA_TOKEN <- Sys.getenv("SOCRATA_APP_TOKEN", "")

## Keep a dated copy of each raw pull alongside latest.parquet? The raw NSSP
## extract is a few MB per week, so this grows the repo substantially over a
## season. The vintage information needed for scoring already lives in
## time-series.parquet, so this defaults off.
ARCHIVE_RAW_SNAPSHOTS <- identical(Sys.getenv("ARCHIVE_RAW_SNAPSHOTS"), "true")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

#' Most recent Wednesday on or before `d` -- the as_of stamp for this run.
last_wednesday <- function(d = Sys.Date()) {
  d <- as.Date(d)
  d - ((as.integer(format(d, "%w")) - 3L) %% 7L)
}

#' Page through a Socrata dataset and return all rows as a tibble.
socrata_fetch <- function(dataset_id, where = NULL, page = 50000L) {
  base <- sprintf("https://data.cdc.gov/resource/%s.csv", dataset_id)
  out <- list()
  offset <- 0L
  repeat {
    q <- c(sprintf("$limit=%d", page), sprintf("$offset=%d", offset), "$order=:id")
    if (!is.null(where)) {
      q <- c(q, paste0("$where=", utils::URLencode(where, reserved = TRUE)))
    }
    if (nzchar(SOCRATA_TOKEN)) q <- c(q, paste0("$$app_token=", SOCRATA_TOKEN))
    url <- paste0(base, "?", paste(q, collapse = "&"))

    chunk <- readr::read_csv(url, col_types = readr::cols(.default = "c"),
                             progress = FALSE)
    out[[length(out) + 1L]] <- chunk
    message(sprintf("  %s: fetched %d rows (offset %d)", dataset_id,
                    nrow(chunk), offset))
    if (nrow(chunk) < page) break
    offset <- offset + page
  }
  dplyr::bind_rows(out)
}

#' Locate a column by exact name, falling back to a case-insensitive regex.
#' Upstream CDC schemas drift (NSSP renamed percent_visits_combined ->
#' percent_visits_ari), so fail loudly rather than silently producing NA.
pick_col <- function(df, exact, pattern, what) {
  if (exact %in% names(df)) return(exact)
  hits <- grep(pattern, names(df), ignore.case = TRUE, value = TRUE)
  if (length(hits) == 1L) {
    warning(sprintf("Column '%s' not found; using '%s' for %s.", exact, hits, what))
    return(hits)
  }
  stop(sprintf(
    paste0("Could not resolve the %s column. Expected '%s'; regex '%s' matched: ",
           "%s.\nAvailable columns: %s"),
    what, exact, pattern,
    if (length(hits)) paste(hits, collapse = ", ") else "nothing",
    paste(names(df), collapse = ", ")
  ))
}

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

locations <- readr::read_csv(
  "auxiliary-data/locations.csv",
  col_types = readr::cols(location = "c", abbreviation = "c",
                          location_name = "c", population = "d")
)
valid_locations <- locations$location

# ---------------------------------------------------------------------------
# NHSN -> weekly incident hospital admissions
# ---------------------------------------------------------------------------

clean_nhsn <- function(raw) {
  c_date <- pick_col(raw, "weekendingdate", "week.*end", "NHSN week ending date")
  c_juris <- pick_col(raw, "jurisdiction", "jurisdiction|geograph", "NHSN jurisdiction")
  c_cov <- pick_col(raw, "totalconfc19newadm", "totalconf.*c19.*newadm", "COVID-19 admissions")
  c_flu <- pick_col(raw, "totalconfflunewadm", "totalconf.*flu.*newadm", "influenza admissions")
  c_rsv <- pick_col(raw, "totalconfrsvnewadm", "totalconf.*rsv.*newadm", "RSV admissions")

  raw |>
    transmute(
      target_end_date = as.Date(substr(.data[[c_date]], 1, 10)),
      abbreviation = toupper(trimws(.data[[c_juris]])),
      `wk inc covid hosp` = suppressWarnings(as.numeric(.data[[c_cov]])),
      `wk inc flu hosp` = suppressWarnings(as.numeric(.data[[c_flu]])),
      `wk inc rsv hosp` = suppressWarnings(as.numeric(.data[[c_rsv]]))
    ) |>
    # NHSN encodes the nation as "USA"; the hub uses "US".
    mutate(abbreviation = if_else(abbreviation == "USA", "US", abbreviation)) |>
    inner_join(select(locations, abbreviation, location), by = "abbreviation") |>
    select(-abbreviation) |>
    pivot_longer(starts_with("wk inc"), names_to = "target",
                 values_to = "observation") |>
    filter(!is.na(target_end_date), !is.na(observation))
}

# ---------------------------------------------------------------------------
# NSSP -> weekly proportion of ED visits
# ---------------------------------------------------------------------------

clean_nssp <- function(raw) {
  c_date <- pick_col(raw, "week_end", "week.?end", "NSSP week end date")
  c_county <- pick_col(raw, "county", "^county$", "NSSP county")
  c_fips <- pick_col(raw, "fips", "^fips$", "NSSP fips")
  c_cov <- pick_col(raw, "percent_visits_covid", "percent_visits_covid", "COVID-19 ED %")
  c_flu <- pick_col(raw, "percent_visits_influenza", "percent_visits_influenza", "influenza ED %")
  c_rsv <- pick_col(raw, "percent_visits_rsv", "percent_visits_rsv", "RSV ED %")

  raw |>
    # county == "All" keeps the state-level and national aggregates and drops
    # the sub-state HSA rows (~97% of the file).
    filter(.data[[c_county]] == "All") |>
    mutate(
      fips_pad = formatC(.data[[c_fips]], width = 5, flag = "0"),
      location = if_else(fips_pad == "00000", "US", substr(fips_pad, 1, 2))
    ) |>
    transmute(
      target_end_date = as.Date(substr(.data[[c_date]], 1, 10)),
      location,
      # CDC reports percent; the hub stores proportion.
      `wk inc covid prop ed visits` = suppressWarnings(as.numeric(.data[[c_cov]])) / 100,
      `wk inc flu prop ed visits` = suppressWarnings(as.numeric(.data[[c_flu]])) / 100,
      `wk inc rsv prop ed visits` = suppressWarnings(as.numeric(.data[[c_rsv]])) / 100
    ) |>
    filter(location %in% valid_locations) |>
    pivot_longer(starts_with("wk inc"), names_to = "target",
                 values_to = "observation") |>
    filter(!is.na(target_end_date), !is.na(observation))
}

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

as_of <- last_wednesday()
message("Building target data with as_of = ", as_of)

message("Fetching NHSN finalized (", NHSN_FINAL_ID, ") ...")
nhsn_final_raw <- socrata_fetch(NHSN_FINAL_ID)

message("Fetching NHSN preliminary (", NHSN_PRELIM_ID, ") ...")
nhsn_prelim_raw <- socrata_fetch(NHSN_PRELIM_ID)

message("Fetching NSSP (source = ", NSSP_SOURCE, ") ...")
nssp_raw <- if (identical(NSSP_SOURCE, "covidhub")) {
  tmp <- tempfile(fileext = ".parquet")
  utils::download.file(NSSP_COVIDHUB_URL, tmp, mode = "wb", quiet = TRUE)
  arrow::read_parquet(tmp) |> mutate(across(everything(), as.character))
} else {
  socrata_fetch(NSSP_ID, where = "county='All'")
}

# ---------------------------------------------------------------------------
# Archive the as-is pulls
# ---------------------------------------------------------------------------

write_raw <- function(df, dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(df, file.path(dir, "latest.parquet"))
  if (ARCHIVE_RAW_SNAPSHOTS) {
    arrow::write_parquet(df, file.path(dir, paste0(as_of, ".parquet")))
  }
}

write_raw(
  bind_rows(
    mutate(nhsn_final_raw, nhsn_release = "final"),
    mutate(nhsn_prelim_raw, nhsn_release = "preliminary")
  ),
  "auxiliary-data/nhsn-raw-data"
)
write_raw(nssp_raw, "auxiliary-data/nssp-raw-data")

# ---------------------------------------------------------------------------
# Clean and combine
# ---------------------------------------------------------------------------

nhsn_final <- clean_nhsn(nhsn_final_raw)
nhsn_prelim <- clean_nhsn(nhsn_prelim_raw)

# Finalized values win. Preliminary only fills weeks the finalized release does
# not carry yet -- on a Wednesday that is the week ending the previous Saturday.
nhsn <- bind_rows(
  nhsn_final,
  anti_join(nhsn_prelim, nhsn_final, by = c("target_end_date", "location", "target"))
)

nssp <- clean_nssp(nssp_raw)

observed <- bind_rows(nhsn, nssp) |>
  distinct(location, target_end_date, target, .keep_all = TRUE) |>
  arrange(target, location, target_end_date)

message(sprintf(
  "Cleaned %d observations across %d targets, %d locations, %s to %s.",
  nrow(observed), dplyr::n_distinct(observed$target),
  dplyr::n_distinct(observed$location),
  min(observed$target_end_date), max(observed$target_end_date)
))

# ---------------------------------------------------------------------------
# time-series.parquet : append this week's vintage
# ---------------------------------------------------------------------------

ts_path <- "target-data/time-series.parquet"
snapshot <- observed |>
  mutate(as_of = as_of) |>
  select(target_end_date, observation, location, as_of, target)

previous <- if (file.exists(ts_path)) {
  arrow::read_parquet(ts_path) |>
    mutate(as_of = as.Date(as_of), target_end_date = as.Date(target_end_date)) |>
    filter(as_of != !!as_of) # idempotent re-run
} else {
  snapshot[0, ]
}

time_series <- bind_rows(previous, snapshot) |>
  arrange(target, as_of, location, target_end_date)

dir.create("target-data", showWarnings = FALSE)
arrow::write_parquet(time_series, ts_path)

# ---------------------------------------------------------------------------
# oracle-output.parquet : latest available value for each observation
# ---------------------------------------------------------------------------

oracle <- observed |>
  transmute(
    location,
    target_end_date,
    target,
    output_type = "quantile",
    oracle_value = observation,
    output_type_id = NA_character_
  ) |>
  arrange(target, location, target_end_date)

arrow::write_parquet(oracle, "target-data/oracle-output.parquet")

message(sprintf(
  "Wrote %s (%d rows, %d as_of snapshots) and oracle-output.parquet (%d rows).",
  ts_path, nrow(time_series), dplyr::n_distinct(time_series$as_of), nrow(oracle)
))
