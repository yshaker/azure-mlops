"""Pipeline step 2 — train, compare candidates, gate on quality, save best model.

* Trains two candidate models (logistic regression vs gradient boosting)
* Logs every metric to MLflow -> visible in Azure ML Studio "Jobs / Metrics"
* Picks the best by ROC-AUC
* FAILS the job if the best model is below --auc_threshold, so a bad model
  can never reach the registry or production (a quality gate)
* Saves the winner in MLflow format, which Azure ML can deploy with no
  scoring script ("no-code deployment")
"""
import argparse
import os
import shutil
import sys
import tempfile

import mlflow
import mlflow.sklearn
import pandas as pd
from mlflow.models.signature import infer_signature
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

TARGET = "churned"
CATEGORICAL = ["contract_type", "payment_method"]
NUMERIC = ["tenure_months", "monthly_charges", "total_charges", "support_tickets_90d", "num_products"]

p = argparse.ArgumentParser()
p.add_argument("--train", required=True)
p.add_argument("--test", required=True)
p.add_argument("--model_output", required=True)
p.add_argument("--auc_threshold", type=float, default=0.75)
a = p.parse_args()

train = pd.read_csv(os.path.join(a.train, "train.csv"))
test = pd.read_csv(os.path.join(a.test, "test.csv"))
X_train, y_train = train[CATEGORICAL + NUMERIC], train[TARGET]
X_test, y_test = test[CATEGORICAL + NUMERIC], test[TARGET]

preprocess = ColumnTransformer(
    [
        ("cat", OneHotEncoder(handle_unknown="ignore"), CATEGORICAL),
        ("num", StandardScaler(), NUMERIC),
    ]
)

candidates = {
    "logreg": LogisticRegression(max_iter=1000, class_weight="balanced"),
    "gbm": GradientBoostingClassifier(n_estimators=200, max_depth=3, learning_rate=0.05, random_state=42),
}

results = {}
for name, estimator in candidates.items():
    pipe = Pipeline([("prep", preprocess), ("model", estimator)])
    pipe.fit(X_train, y_train)
    proba = pipe.predict_proba(X_test)[:, 1]
    pred = (proba >= 0.5).astype(int)
    metrics = {
        "auc": roc_auc_score(y_test, proba),
        "accuracy": accuracy_score(y_test, pred),
        "precision": precision_score(y_test, pred, zero_division=0),
        "recall": recall_score(y_test, pred),
        "f1": f1_score(y_test, pred),
    }
    for k, v in metrics.items():
        mlflow.log_metric(f"{name}_{k}", v)
    results[name] = (metrics["auc"], pipe)
    print(f"{name}: " + ", ".join(f"{k}={v:.3f}" for k, v in metrics.items()))

best_name, (best_auc, best_pipe) = max(results.items(), key=lambda kv: kv[1][0])
mlflow.log_param("best_model", best_name)
mlflow.log_metric("best_auc", best_auc)
print(f"Best: {best_name} (AUC {best_auc:.3f}), threshold {a.auc_threshold}")

# ---- Quality gate --------------------------------------------------------
if best_auc < a.auc_threshold:
    print("Quality gate FAILED — model not saved, job will fail.")
    sys.exit(1)

# ---- Save in MLflow format (signature = the API contract) ----------------
# pyfunc_predict_fn="predict_proba" makes the endpoint return
# [P(stay), P(churn)] per customer instead of a bare 0/1 label.
signature = infer_signature(X_test, best_pipe.predict_proba(X_test))
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "model")
    mlflow.sklearn.save_model(
        best_pipe,
        path,
        signature=signature,
        input_example=X_test.head(2),
        pyfunc_predict_fn="predict_proba",
    )
    os.makedirs(a.model_output, exist_ok=True)
    shutil.copytree(path, a.model_output, dirs_exist_ok=True)
print(f"Model saved to {a.model_output}")
