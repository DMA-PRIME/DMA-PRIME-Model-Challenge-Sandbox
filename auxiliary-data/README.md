# Auxiliary data

Supporting data for the **DMA-PRIME Model Challenge**. Everything here is public.

## `locations.csv`

The location crosswalk for the hub: the nation, the 50 states, the District of
Columbia, and Puerto Rico (53 rows).

| Column | Description |
|---|---|
| `abbreviation` | Two letter postal abbreviation, `US` for national |
| `location` | Hub location code: 2 digit FIPS, or `"US"` |
| `location_name` | Full name |
| `population` | Population denominator |

`location` is the value that appears in submissions and in the target data.
`abbreviation` exists because NHSN identifies jurisdictions by postal abbreviation
(and the nation as `USA`), so the pipeline joins on it. NSSP instead carries a
5 digit `fips` field, which the pipeline truncates to its first two digits.

State populations sum to slightly more than the `US` row because the national NHSN
figure excludes Puerto Rico. This matches the FluSight crosswalk this file is
derived from.

## `nhsn-raw-data/` and `nssp-raw-data/`

The **as pulled** CDC extracts, stored exactly as retrieved with no cleaning,
renaming, filtering, or type coercion applied. These exist so that any cleaning
decision made in [`scripts/get_target_data.R`](../scripts/get_target_data.R) can be
audited or redone against the original input.

- `latest.parquet` is overwritten on every Wednesday run.
- `<YYYY-MM-DD>.parquet` dated copies are written only when the pipeline runs with
  `ARCHIVE_RAW_SNAPSHOTS=true`.

Dated archives are **off by default**. The raw NSSP extract is several MB per week,
so keeping every snapshot would grow the repository substantially over a season, and
the vintage information that actually matters for scoring is already captured in
`target-data/time-series.parquet` in a far more compact form. Turn the archives on
for a stretch when you specifically need to audit raw upstream revisions.

### `nhsn-raw-data/latest.parquet`

Rows from both NHSN releases, stacked, with one added column:

| Column | Description |
|---|---|
| `nhsn_release` | `"final"` (dataset `ua7e-t2fy`) or `"preliminary"` (`mpgq-jmmr`) |

Every other column is upstream's, unmodified. The pipeline reads
`weekendingdate`, `jurisdiction`, `totalconfc19newadm`, `totalconfflunewadm`, and
`totalconfrsvnewadm`; the rest (bed capacity, occupancy, ICU, age breakdowns,
reporting coverage) is carried along and available for use as covariates.

### `nssp-raw-data/latest.parquet`

The NSSP ED visit trajectories extract, filtered server side to `county = 'All'`,
which keeps the state level and national aggregates and drops the sub state Health
Service Area rows. That filter is a volume reduction, roughly 480,000 rows down to
about 10,000, not a cleaning step: no values are altered.

Relevant columns include `week_end`, `geography`, `county`, `fips`, `trend_source`,
and `percent_visits_covid` / `percent_visits_influenza` / `percent_visits_rsv`. Note
that these percentages are stored here **as CDC publishes them**, in percent. The
conversion to proportion happens downstream, in the target data.

> [!NOTE]
> Upstream schemas drift. NSSP has already renamed `percent_visits_combined` to
> `percent_visits_ari` and added threshold classification columns. The pipeline
> resolves each column it needs by exact name first and a regex fallback second, and
> **errors loudly** rather than silently emitting `NA` if a column cannot be
> resolved. If a Wednesday run fails with a "Could not resolve" error, compare the
> column list in the error against `latest.parquet` and update the corresponding
> `pick_col()` call.
