"""Generate hub-config/tasks.json for the DMA-PRIME Model Challenge.

Seasons follow the NHSN "Respiratory Virus Season" convention: season Y/Y+1 runs
from the Saturday ending MMWR week 40 of year Y through the Saturday ending MMWR
week 39 of year Y+1. Rounds are year-round within each season (no seasonal gap),
but each season is a separate round object, FluSight-style.
"""

import json
from datetime import date, timedelta

QUANTILES = [0.01, 0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45,
             0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 0.975, 0.99]

HORIZONS = [0, 1, 2, 3]

# NSSP publishes ED visit percentages for the nation, the 50 states and DC, but
# NOT Puerto Rico. Verified against the live extract: 52 of the hub's 53
# locations appear. Listing PR on the ED targets would invite forecasts that can
# never be scored, so it is excluded from that model task only.
ED_EXCLUDE = ["72"]

PATHOGENS = [
    ("covid", "COVID-19"),
    ("flu", "influenza"),
    ("rsv", "RSV"),
]


def mmwr_week1_end(year):
    """Saturday ending MMWR week 1 of `year`: first Saturday on or after Jan 4."""
    d = date(year, 1, 4)
    return d + timedelta(days=(5 - d.weekday()) % 7)


def season_saturdays(start_year):
    """All Saturdays in season start_year/start_year+1 (MMWR wk40 -> next wk39)."""
    first = mmwr_week1_end(start_year) + timedelta(weeks=39)          # week 40
    last = mmwr_week1_end(start_year + 1) + timedelta(weeks=38)       # week 39
    out, d = [], first
    while d <= last:
        out.append(d)
        d += timedelta(weeks=1)
    return out


def hosp_model_task(ref_dates, end_dates):
    return {
        "task_ids": {
            "reference_date": {"required": None, "optional": ref_dates},
            "target": {
                "required": None,
                "optional": [f"wk inc {p} hosp" for p, _ in PATHOGENS],
            },
            "horizon": {"required": None, "optional": HORIZONS},
            "location": {"required": None, "optional": LOCATIONS},
            "target_end_date": {"required": None, "optional": end_dates},
        },
        "output_type": {
            "quantile": {
                "output_type_id": {"required": QUANTILES},
                "is_required": True,
                "value": {"type": "double", "minimum": 0},
            }
        },
        "target_metadata": [
            {
                "target_id": f"wk inc {p} hosp",
                "target_name": f"incident {label} hospitalizations",
                "target_units": "count",
                "target_keys": {"target": f"wk inc {p} hosp"},
                "description": (
                    f"Weekly count of new laboratory-confirmed {label} hospital "
                    "admissions reported to NHSN for the week ending on the "
                    "target_end_date."
                ),
                "target_type": "discrete",
                "is_step_ahead": True,
                "time_unit": "week",
            }
            for p, label in PATHOGENS
        ],
    }


def ed_model_task(ref_dates, end_dates):
    return {
        "task_ids": {
            "reference_date": {"required": None, "optional": ref_dates},
            "target": {
                "required": None,
                "optional": [f"wk inc {p} prop ed visits" for p, _ in PATHOGENS],
            },
            "horizon": {"required": None, "optional": HORIZONS},
            "location": {
                "required": None,
                "optional": [l for l in LOCATIONS if l not in ED_EXCLUDE],
            },
            "target_end_date": {"required": None, "optional": end_dates},
        },
        "output_type": {
            "quantile": {
                "output_type_id": {"required": QUANTILES},
                "is_required": True,
                "value": {"type": "double", "minimum": 0, "maximum": 1},
            }
        },
        "target_metadata": [
            {
                "target_id": f"wk inc {p} prop ed visits",
                "target_name": (
                    f"proportion of weekly incident ED visits due to {label}"
                ),
                "target_units": "proportion",
                "target_keys": {"target": f"wk inc {p} prop ed visits"},
                "description": (
                    "Proportion of emergency department visits due to "
                    f"{label} reported to NSSP for the week ending on the "
                    "target_end_date. Reported by CDC as a percentage; submitted "
                    "and scored here as a decimal proportion between 0 and 1."
                ),
                "target_type": "continuous",
                "is_step_ahead": True,
                "time_unit": "week",
            }
            for p, label in PATHOGENS
        ],
    }


def build_round(start_year):
    sats = season_saturdays(start_year)
    ref_dates = [d.isoformat() for d in sats]
    ends = sorted({d + timedelta(weeks=h) for d in sats for h in HORIZONS})
    end_dates = [d.isoformat() for d in ends]
    return {
        "round_id_from_variable": True,
        "round_id": "reference_date",
        "model_tasks": [
            hosp_model_task(ref_dates, end_dates),
            ed_model_task(ref_dates, end_dates),
        ],
        # Submission window opens Sunday (reference_date - 6) and closes
        # Wednesday 11:59pm (reference_date - 3), matching FluSight/CovidHub.
        "submissions_due": {"relative_to": "reference_date", "start": -6, "end": -3},
    }


if __name__ == "__main__":
    import csv
    import sys

    with open(sys.argv[1]) as f:
        LOCATIONS = [r["location"] for r in csv.DictReader(f)]

    args = sys.argv[3:]
    # --single-round emits one round covering every season (FluSight's own
    # layout). Default is one round per season.
    single = "--single-round" in args
    seasons = [int(y) for y in args if y != "--single-round"]

    if single:
        sats = [d for y in seasons for d in season_saturdays(y)]
        sats = sorted(set(sats))
        ref_dates = [d.isoformat() for d in sats]
        ends = sorted({d + timedelta(weeks=h) for d in sats for h in HORIZONS})
        end_dates = [d.isoformat() for d in ends]
        rounds = [{
            "round_id_from_variable": True,
            "round_id": "reference_date",
            "model_tasks": [
                hosp_model_task(ref_dates, end_dates),
                ed_model_task(ref_dates, end_dates),
            ],
            "submissions_due": {
                "relative_to": "reference_date", "start": -6, "end": -3
            },
        }]
    else:
        rounds = [build_round(y) for y in seasons]

    cfg = {
        "schema_version": (
            "https://raw.githubusercontent.com/hubverse-org/schemas/main/"
            "v6.0.0/tasks-schema.json"
        ),
        "rounds": rounds,
        "output_type_id_datatype": "auto",
        "derived_task_ids": ["target_end_date"],
    }
    with open(sys.argv[2], "w") as f:
        json.dump(cfg, f, indent=4)
        f.write("\n")

    for y in seasons:
        s = season_saturdays(y)
        print(f"season {y}-{y+1}: {s[0]} -> {s[-1]}  ({len(s)} reference dates)")
    print(f"locations: {len(LOCATIONS)}")
