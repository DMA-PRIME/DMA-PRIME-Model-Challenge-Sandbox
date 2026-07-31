#' Build target data for the Human-AI Teaming forecast challenge (hubverse)
#'
#' Run every week from the .github workflow. Produces, from the hub root:
#'
#'   auxiliary-data/nhsn-raw-data/latest.parquet   as-is NHSN pull (no cleaning)
#'   auxiliary-data/nssp-raw-data/latest.parquet   as-is NSSP pull (no cleaning)
#'   target-data/time-series.parquet               VERSIONED observed series
#'   target-data/oracle-output.parquet             settled scoring truth
#'
#' WHAT MAKES THE DASHBOARD WORK
#' ----------------------------------------------------------------------------
#' predtimechart looks up the observed ("truth") line by `as_of = reference_date`.
#' If the time-series has no `as_of` column it only renders truth at the newest
#' week; every earlier week loses its observed line and the "current" marker no
#' longer matches the data. This script therefore writes a *vintaged* series:
#' for every forecast reference date R declared in hub-config/tasks.json it emits
#' one `as_of = R` snapshot containing the observed history through week R.
#'
#' SELF-SCOPING (no code edits when the hub grows)
#' ----------------------------------------------------------------------------
#' Targets, locations, and reference dates are all read from hub-config/tasks.json.
#' Add COVID/RSV, more states, ED-visit targets, or another season to tasks.json
#' and this script picks them up automatically -- it pulls all six NHSN+NSSP
#' targets and keeps whatever the config declares.
#'
#' NOTE ON BACKFILL. Each snapshot uses the currently-reported value for each
#' week, truncated by date. That fixes the observed line at every week but does
#' not reproduce real-time reporting revisions (backfill). To capture true
#' vintages going forward, switch the time-series block to append-one-live-
#' snapshot-per-run (see the DMA-PRIME hub's get_target_data.R) instead of
#' regenerating; the two are interchangeable and both are versioned.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(jsonlite)
  library(arrow)
})

options(timeout = 1200)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NHSN_FINAL_ID  <- "ua7e-t2fy"  # Weekly HRD Metrics by Jurisdiction (published Fri)
NHSN_PRELIM_ID <- "mpgq-jmmr"  # ...same, Preliminary               (published Wed)
NSSP_ID        <- "rdmq-nq56"  # NSSP ED Visit Trajectories          (published Fri)

## NSSP source: "covidhub" (Wednesday mirror, one week fresher, more reliable from
## CI) or "cdc" (data.cdc.gov Socrata API, self-contained).
NSSP_SOURCE <- Sys.getenv("NSSP_SOURCE", "covidhub")
NSSP_COVIDHUB_URL <- paste0(
  "https://raw.githubusercontent.com/CDCgov/covid19-forecast-hub/",
  "main/auxiliary-data/nssp-raw-data/latest.parquet"
)

SOCRATA_TOKEN <- Sys.getenv("SOCRATA_APP_TOKEN", "")

## Truncation boundary: how far back from a reference date R the observed line is
## drawn. 0 => weeks with target_end_date <= R (the reference week and earlier).
## Set e.g. 7 for a stricter "what was actually reported by R" cutoff.
CUTOFF_LAG_DAYS <- as.integer(Sys.getenv("CUTOFF_LAG_DAYS", "0"))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

socrata_fetch <- function(dataset_id, where = NULL, page = 50000L) {
  base <- sprintf("https://data.cdc.gov/resource/%s.csv", dataset_id)
  out <- list(); offset <- 0L
  repeat {
    q <- c(sprintf("$limit=%d", page), sprintf("$offset=%d", offset), "$order=:id")
    if (!is.null(where)) q <- c(q, paste0("$where=", utils::URLencode(where, reserved = TRUE)))
    if (nzchar(SOCRATA_TOKEN)) q <- c(q, paste0("$$app_token=", SOCRATA_TOKEN))
    url <- paste0(base, "?", paste(q, collapse = "&"))
    chunk <- readr::read_csv(url, col_types = readr::cols(.default = "c"), progress = FALSE)
    out[[length(out) + 1L]] <- chunk
    message(sprintf("  %s: fetched %d rows (offset %d)", dataset_id, nrow(chunk), offset))
    if (nrow(chunk) < page) break
    offset <- offset + page
  }
  dplyr::bind_rows(out)
}

#' Locate a column by exact name, falling back to a case-insensitive regex.
pick_col <- function(df, exact, pattern, what) {
  if (exact %in% names(df)) return(exact)
  hits <- grep(pattern, names(df), ignore.case = TRUE, value = TRUE)
  if (length(hits) == 1L) {
    warning(sprintf("Column '%s' not found; using '%s' for %s.", exact, hits, what))
    return(hits)
  }
  stop(sprintf("Could not resolve the %s column. Expected '%s'; regex '%s' matched: %s.\nAvailable: %s",
               what, exact, pattern,
               if (length(hits)) paste(hits, collapse = ", ") else "nothing",
               paste(names(df), collapse = ", ")))
}

# ---------------------------------------------------------------------------
# Read what the hub declares (targets, locations, reference dates)
# ---------------------------------------------------------------------------

locations <- readr::read_csv(
  "auxiliary-data/locations.csv",
  col_types = readr::cols(location = "c", abbreviation = "c",
                          location_name = "c", population = "d")
)

tasks <- jsonlite::fromJSON("hub-config/tasks.json", simplifyVector = FALSE)
model_tasks <- tasks$rounds[[1]]$model_tasks
opt_values <- function(field) {
  unique(unlist(lapply(model_tasks, function(mt) {
    c(mt$task_ids[[field]]$required, mt$task_ids[[field]]$optional)
  })))
}
hub_targets   <- opt_values("target")
hub_locations <- opt_values("location")
ref_dates     <- sort(as.Date(unlist(opt_values("reference_date"))))
ref_dates     <- ref_dates[ref_dates <= Sys.Date()]   # only weeks that have arrived

message(sprintf("Hub declares %d target(s), %d location(s), %d reference date(s) (<= today).",
                length(hub_targets), length(hub_locations), length(ref_dates)))

# ---------------------------------------------------------------------------
# NHSN -> weekly incident hospital admissions (all three pathogens)
# ---------------------------------------------------------------------------

clean_nhsn <- function(raw) {
  c_date  <- pick_col(raw, "weekendingdate", "week.*end", "NHSN week ending date")
  c_juris <- pick_col(raw, "jurisdiction", "jurisdiction|geograph", "NHSN jurisdiction")
  c_cov   <- pick_col(raw, "totalconfc19newadm", "totalconf.*c19.*newadm", "COVID-19 admissions")
  c_flu   <- pick_col(raw, "totalconfflunewadm", "totalconf.*flu.*newadm", "influenza admissions")
  c_rsv   <- pick_col(raw, "totalconfrsvnewadm", "totalconf.*rsv.*newadm", "RSV admissions")
  raw |>
    transmute(
      target_end_date = as.Date(substr(.data[[c_date]], 1, 10)),
      abbreviation = toupper(trimws(.data[[c_juris]])),
      `wk inc covid hosp` = suppressWarnings(as.numeric(.data[[c_cov]])),
      `wk inc flu hosp`   = suppressWarnings(as.numeric(.data[[c_flu]])),
      `wk inc rsv hosp`   = suppressWarnings(as.numeric(.data[[c_rsv]]))
    ) |>
    mutate(abbreviation = if_else(abbreviation == "USA", "US", abbreviation)) |>
    inner_join(select(locations, abbreviation, location), by = "abbreviation") |>
    select(-abbreviation) |>
    pivot_longer(starts_with("wk inc"), names_to = "target", values_to = "observation") |>
    filter(!is.na(target_end_date), !is.na(observation))
}

# ---------------------------------------------------------------------------
# NSSP -> weekly proportion of ED visits (all three pathogens)
# ---------------------------------------------------------------------------

clean_nssp <- function(raw) {
  c_date   <- pick_col(raw, "week_end", "week.?end", "NSSP week end date")
  c_county <- pick_col(raw, "county", "^county$", "NSSP county")
  c_fips   <- pick_col(raw, "fips", "^fips$", "NSSP fips")
  c_cov    <- pick_col(raw, "percent_visits_covid", "percent_visits_covid", "COVID-19 ED %")
  c_flu    <- pick_col(raw, "percent_visits_influenza", "percent_visits_influenza", "influenza ED %")
  c_rsv    <- pick_col(raw, "percent_visits_rsv", "percent_visits_rsv", "RSV ED %")
  raw |>
    filter(.data[[c_county]] == "All") |>
    mutate(
      fips_pad = formatC(.data[[c_fips]], width = 5, flag = "0"),
      location = if_else(fips_pad == "00000", "US", substr(fips_pad, 1, 2))
    ) |>
    transmute(
      target_end_date = as.Date(substr(.data[[c_date]], 1, 10)),
      location,
      # CDC reports percent; the hub stores decimal proportion.
      `wk inc covid prop ed visits` = suppressWarnings(as.numeric(.data[[c_cov]])) / 100,
      `wk inc flu prop ed visits`   = suppressWarnings(as.numeric(.data[[c_flu]])) / 100,
      `wk inc rsv prop ed visits`   = suppressWarnings(as.numeric(.data[[c_rsv]])) / 100
    ) |>
    pivot_longer(starts_with("wk inc"), names_to = "target", values_to = "observation") |>
    filter(!is.na(target_end_date), !is.na(observation))
}

# ---------------------------------------------------------------------------
# Fetch (only what the hub actually declares)
# ---------------------------------------------------------------------------

need_nhsn <- any(grepl("hosp$", hub_targets))
need_nssp <- any(grepl("prop ed visits$", hub_targets))

nhsn <- tibble()
if (need_nhsn) {
  message("Fetching NHSN finalized (", NHSN_FINAL_ID, ") ...")
  nhsn_final_raw  <- socrata_fetch(NHSN_FINAL_ID)
  message("Fetching NHSN preliminary (", NHSN_PRELIM_ID, ") ...")
  nhsn_prelim_raw <- socrata_fetch(NHSN_PRELIM_ID)

  dir.create("auxiliary-data/nhsn-raw-data", recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(
    bind_rows(mutate(nhsn_final_raw, nhsn_release = "final"),
              mutate(nhsn_prelim_raw, nhsn_release = "preliminary")),
    "auxiliary-data/nhsn-raw-data/latest.parquet")

  nhsn_final  <- clean_nhsn(nhsn_final_raw)
  nhsn_prelim <- clean_nhsn(nhsn_prelim_raw)
  # Finalized wins; preliminary only fills weeks finalized doesn't carry yet.
  nhsn <- bind_rows(
    nhsn_final,
    anti_join(nhsn_prelim, nhsn_final, by = c("target_end_date", "location", "target"))
  )
}

nssp <- tibble()
if (need_nssp) {
  message("Fetching NSSP (source = ", NSSP_SOURCE, ") ...")
  nssp_raw <- if (identical(NSSP_SOURCE, "covidhub")) {
    tmp <- tempfile(fileext = ".parquet")
    utils::download.file(NSSP_COVIDHUB_URL, tmp, mode = "wb", quiet = TRUE)
    arrow::read_parquet(tmp) |> mutate(across(everything(), as.character))
  } else {
    socrata_fetch(NSSP_ID, where = "county='All'")
  }
  dir.create("auxiliary-data/nssp-raw-data", recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(nssp_raw, "auxiliary-data/nssp-raw-data/latest.parquet")
  nssp <- clean_nssp(nssp_raw)
}

# ---------------------------------------------------------------------------
# Scope to what the hub declares
# ---------------------------------------------------------------------------

observed <- bind_rows(nhsn, nssp) |>
  filter(target %in% hub_targets, location %in% hub_locations) |>
  distinct(location, target_end_date, target, .keep_all = TRUE) |>
  arrange(target, location, target_end_date)

if (nrow(observed) == 0) stop("No observed rows after scoping to the hub's declared targets/locations.")
message(sprintf("Scoped to %d observations, %s to %s.",
                nrow(observed), min(observed$target_end_date), max(observed$target_end_date)))

# ---------------------------------------------------------------------------
# time-series.parquet : one vintaged snapshot per reference date
# ---------------------------------------------------------------------------

make_snapshot <- function(R) {
  observed |>
    filter(target_end_date <= R - CUTOFF_LAG_DAYS) |>
    mutate(as_of = R)
}
time_series <- bind_rows(lapply(ref_dates, make_snapshot)) |>
  transmute(target_end_date, observation, location, as_of, target) |>
  arrange(target, as_of, location, target_end_date)

dir.create("target-data", showWarnings = FALSE)
arrow::write_parquet(time_series, "target-data/time-series.parquet")

# ---------------------------------------------------------------------------
# oracle-output.parquet : settled truth (latest available value per week)
# ---------------------------------------------------------------------------

oracle <- observed |>
  transmute(location, target_end_date, target,
            output_type = "quantile", oracle_value = observation,
            output_type_id = NA_character_) |>
  arrange(target, location, target_end_date)
arrow::write_parquet(oracle, "target-data/oracle-output.parquet")

message(sprintf("Wrote time-series.parquet (%d rows, %d as_of snapshots) and oracle-output.parquet (%d rows).",
                nrow(time_series), dplyr::n_distinct(time_series$as_of), nrow(oracle)))
