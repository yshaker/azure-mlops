"""Pipeline step 1 — data preparation.

Reads the raw CSV (an Azure ML data asset), cleans it, and writes a stratified
train/test split to the step's output folders.
"""
import argparse
import os

import mlflow
import pandas as pd
from sklearn.model_selection import train_test_split

p = argparse.ArgumentParser()
p.add_argument("--raw", required=True, help="Path to raw CSV")
p.add_argument("--train", required=True, help="Output folder for train.csv")
p.add_argument("--test", required=True, help="Output folder for test.csv")
p.add_argument("--test_size", type=float, default=0.2)
a = p.parse_args()

df = pd.read_csv(a.raw)
rows_in = len(df)

# Basic cleaning — the kind of thing you'd expand in a real project
df = df.drop_duplicates(subset="customer_id")
df = df.dropna(subset=["churned"])
df["total_charges"] = pd.to_numeric(df["total_charges"], errors="coerce").fillna(0)
df = df.drop(columns=["customer_id"])  # identifiers are not features

train, test = train_test_split(df, test_size=a.test_size, stratify=df["churned"], random_state=42)

os.makedirs(a.train, exist_ok=True)
os.makedirs(a.test, exist_ok=True)
train.to_csv(os.path.join(a.train, "train.csv"), index=False)
test.to_csv(os.path.join(a.test, "test.csv"), index=False)

mlflow.log_metric("rows_in", rows_in)
mlflow.log_metric("rows_clean", len(df))
mlflow.log_metric("churn_rate", float(df["churned"].mean()))
print(f"prep: {rows_in} -> {len(df)} rows; train={len(train)} test={len(test)}")
