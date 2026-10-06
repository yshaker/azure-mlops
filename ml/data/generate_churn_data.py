"""Generate a synthetic customer-churn dataset.

In a real project this data would land in the Data Lake from CRM/billing
systems (e.g. via Data Factory or Fabric). Here we fake it so the whole
pipeline is runnable end to end.

Usage: python generate_churn_data.py --rows 5000 --out churn_raw.csv
"""
import argparse

import numpy as np
import pandas as pd


def generate(rows: int, seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)

    tenure = rng.integers(1, 72, rows)
    contract = rng.choice(["month-to-month", "one-year", "two-year"], rows, p=[0.55, 0.25, 0.20])
    payment = rng.choice(["credit-card", "bank-transfer", "e-check", "mailed-check"], rows)
    monthly = np.round(rng.normal(70, 25, rows).clip(15, 150), 2)
    total = np.round(monthly * tenure * rng.uniform(0.9, 1.05, rows), 2)
    tickets = rng.poisson(1.2, rows)
    products = rng.integers(1, 6, rows)

    # Churn drivers: short tenure, monthly contracts, e-check, high price, many tickets
    logit = (
        -1.2
        - 0.045 * tenure
        + 1.3 * (contract == "month-to-month")
        - 0.8 * (contract == "two-year")
        + 0.6 * (payment == "e-check")
        + 0.015 * (monthly - 70)
        + 0.45 * tickets
        - 0.25 * products
    )
    churn = rng.random(rows) < 1 / (1 + np.exp(-logit))

    return pd.DataFrame(
        {
            "customer_id": [f"C{i:06d}" for i in range(rows)],
            "tenure_months": tenure,
            "contract_type": contract,
            "payment_method": payment,
            "monthly_charges": monthly,
            "total_charges": total,
            "support_tickets_90d": tickets,
            "num_products": products,
            "churned": churn.astype(int),
        }
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--rows", type=int, default=5000)
    p.add_argument("--out", default="churn_raw.csv")
    a = p.parse_args()
    df = generate(a.rows)
    df.to_csv(a.out, index=False)
    print(f"Wrote {len(df)} rows to {a.out} (churn rate {df.churned.mean():.1%})")
