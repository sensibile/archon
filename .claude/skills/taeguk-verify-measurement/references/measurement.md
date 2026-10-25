# Measurement evidence

Define the user outcome before choosing a proxy. For every metric carry its name, purpose, numerator, denominator/population, inclusion/exclusion rules, time window and timezone, dimensions, units, source, collection version, freshness, missing/duplicate policy, uncertainty, approved threshold source and action. A threshold proposal is not an approved gate.

For availability, count eligible outcomes at the chosen boundary; distinguish success, failure and unobserved outcomes. State whether retries count requests or user operations. Never discard unknowns to improve the ratio. For latency report percentiles with sample size/window and treatment of errors/timeouts; an average is not a percentile. For saturation define the resource and capacity baseline. Traffic alone is workload, not user benefit.

For SLO/error-budget calculations preserve the SLI definition, objective and period; a burn-rate interpretation needs the approved objective and matching windows. For user-effect metrics, state the causal limitations and plausible confounders; deployment timing alone does not establish causality.

Check measurement separately from product judgment: reconcile totals with raw events or another source, sample query results, check joins/grain/duplicates, probe a known failure and recovery, and verify timezone/window boundaries. Record missingness and observation coverage. UNKNOWN data quality cannot silently become a PASS gate.

Taeguk measure computes success bounds for supplied counts only. It cannot discover ingestion loss, establish independence, calculate percentiles or confirm a production SLO. Taeguk verify checks file identity and declared statuses only. Use external collection and observation tools where required.

Return definition, source/query and version, reconciled population, data-quality result, metric result, approved comparison, evidence and limitations. If no approved objective exists, return measured facts with judgment UNKNOWN.
