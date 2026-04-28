---
title: "DEEP-1B on a Single Node: Practical Billion-Scale Vector Search with VectorChord 1.0.0"
description: "Benchmarking VectorChord 1.0.0 on Yandex DEEP-1B with practical build time, latency, and hardware requirements for self-hosted teams."
author: "vectorchord"
pubDate: 2026-04-27
heroImage: ../../../assets/covers/vectorchord-deep-1b-benchmark.svg
---

For teams trying to run vector search at billion scale themselves, the challenge is often not raw performance, but practicality. Many solutions designed for billion-scale, low-latency vector search come with practical constraints, requiring tradeoffs that affect how easily they can be adopted.

Most existing approaches fall into one of a few categories:

- **Operationally complex**: Powered by multi-node distributed systems that are difficult to manage, operate, and maintain over time.
- **Build-time prohibitive**: Requiring long index build times, which makes re-indexing costly and can impact production workloads.
- **Memory heavy**: Depending on up to 1 TB of memory on a single machine, making the hardware significantly less affordable for most teams.

These tradeoffs are visible in existing public benchmarks. For example, [ScyllaDB](https://www.scylladb.com/2025/12/01/scylladb-vector-search-1b-benchmark/) reports up to 98% recall with a P99 latency of 12.3 ms on DEEP-1B, but this result depends on multiple large instances. [YugabyteDB](https://www.yugabyte.com/blog/benchmarking-1-billion-vectors-in-yugabytedb/), on the same dataset, reports significantly higher tail latency, with P99 reaching 0.319 seconds at the same scale.

|  | Latency / Recall | Hardware | Build time |
| --- | --- | --- | --- |
| ScyllaDB | 13 ms / 98% | 3x`AWS r7i.48xlarge` + 3x`AWS i4i.16xlarge` | 24.4 h |
| YugabyteDB | 319 ms / 96% | Not reported | Not reported |
| VectorChord | 40 ms / 95% | `AWS i7ie.6xlarge` | 1.8 h |

For single-node deployments, previous work from [Scalable Vector Search (SVS)](https://intel.github.io/ScalableVectorSearch/benchs/static/previous/large_scale_benchs.html#search-with-reduced-memory-footprint) shows that indexing DEEP-1B with [HNSWlib](https://github.com/nmslib/hnswlib) typically requires 800 GiB of memory, though SVS or [FAISS-IVFPQs](https://github.com/facebookresearch/faiss) can reduce it to around 300 GiB, which is still a substantial hardware requirement.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1768291667540/ec225f8e-015a-4832-9aef-c5227a545a67.png)

This makes smooth scaling difficult for teams that want to stay self-hosted. Moving from 1 million to 1 billion vectors often requires rethinking architecture, hardware assumptions, or workflow.

With [VectorChord 1.0.0](https://blog.vectorchord.ai/vectorchord-10-developer-first-vector-search-on-postgres-100x-faster-indexing-than-pgvector), scaling is much easier. By taking advantage of [Hierarchical K-means and other optimizations](https://blog.vectorchord.ai/how-we-made-100m-vector-indexing-in-20-minutes-possible-on-postgresql), indexing 1B vectors follows the same process as indexing 1M vectors. This is also how we use it internally: simply move to a slightly larger machine, for example from an AWS i7i.xlarge to an i7i.4xlarge.

## The DEEP-1B Benchmark

To validate VectorChord's capability at the billion-vector scale, we use the [Yandex DEEP-1B](https://research.yandex.com/datasets/biganns) dataset from [BIGANN](https://big-ann-benchmarks.com/neurips21.html). DEEP-1B is a widely adopted benchmark for large-scale vector search, consisting of **1 billion 96-dimensional embeddings** generated from deep learning models trained on natural images.

Because of its scale, DEEP-1B is widely used to evaluate large-scale vector search systems. Its broad adoption makes results easy to reproduce and compare, particularly for indexing performance, query latency, and resource efficiency at billion scale.

For this dataset, building a VectorChord index requires:

- **Storage**: Approximately **900 GB** of high-performance SSD
- **Memory ([`shared_buffers`](https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-SHARED-BUFFERS))**: At least **60 GB**, managed by PostgreSQL
- **Memory (extra)**: At least **60 GB extra** during index construction

Based on these requirements, an `AWS i7i.4xlarge` is the minimum configuration for indexing at this scale. Our tests were run on an `AWS i7ie.6xlarge`, reflecting practical deployments where additional memory is provisioned to reduce disk access and maintain stable query latency.

| instance | `AWS i7i.4xlarge` | `AWS i7ie.6xlarge` |
| --- | --- | --- |
| Physical Processor | Intel Xeon Scalable (Emerald Rapids) | Intel Xeon Scalable (Emerald Rapids) |
| vCPUs | 16 | 24 |
| Memory (GiB) | 128 | 192 |
| Disk Space (GiB) | 3750 GB NVMe SSD | 2x7500 GB NVMe SSD |
| Price | **$1088** monthly | **$2246** monthly |

All experiments were run with VectorChord 1.0.0 on PostgreSQL 17. The SQL below is the exact command we used to build the index:

```pgsql
CREATE INDEX ON deep USING vchordrq (embedding vector_l2_ops) WITH (options = $$
build.pin = 2
residual_quantization = true
[build.internal]
build_threads = 24
lists = [800, 640000]
kmeans_algorithm.hierarchical = {}
$$);
```

Here is what each option does in our build configuration:

- [`build.pin`](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#build-pin): Enables build-time pinning, caching the hot portion of the index in shared memory to speed up indexing on large datasets.
- [`residual_quantization`](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#residual-quantization): On DEEP-1B, enabling **residual quantization** improves query performance, so we keep it on for this benchmark.
- [`build.internal.build_threads`](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#build-internal-build-threads): Uses 24 threads for the K-means build stage, helping saturate available CPU resources on the instance.
- [`build.internal.lists`](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#build-internal-lists): We choose lists based on row count; using a **two-level list** helps significantly at large scale, improving both index build efficiency and query performance.
- [`build.internal.kmeans_algorithm.hierarchical`](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#build-internal-kmeans-algorithm): Enables the **Hierarchical K-means** path introduced in VectorChord 1.0, which significantly accelerates index construction at scale.

## Our results

Index construction completed in **6,408 seconds (about 1.8 hours)** while utilizing **24 CPU cores** on a single AWS i7ie.6xlarge machine, demonstrating that billion-scale indexing can be completed within a practical window.

The figure shows query throughput versus recall on DEEP-1B using a single search thread, evaluated for both Top-10 and Top-100 queries, with all queries run against a warm cache.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1767855767038/b2a769c9-0d5d-48d6-ab2f-791d6bac7e29.png)

For Top-10, throughput ranges from over 117 QPS at about 0.91 recall to around 69 QPS at about 0.95 recall. Top-100 queries follow the same pattern, with throughput decreasing as recall increases.

The table below lists the exact search parameters behind each data point, varying the number of probes while keeping `epsilon = 1.9` fixed. Together, the figure and table show that even at 1B-vector scale, VectorChord provides stable and tunable query performance on a single machine.

| [probes](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#vchordrq-probes) / [epsilon](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#vchordrq-epsilon) | Recall@Top 10 | QPS | P99 latency / ms |
| --- | --- | --- | --- |
| 40,120 / 1.9 | 0.9132 | 117.45 | 12.33 |
| 40,160 / 1.9 | 0.9305 | 97.32 | 14.61 |
| 40,250 / 1.9 | 0.9511 | 68.87 | 20.53 |

| [probes](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#vchordrq-probes) / [epsilon](https://docs.vectorchord.ai/vectorchord/usage/indexing.html#vchordrq-epsilon) | Recall@Top 100 | QPS | P99 latency / ms |
| --- | --- | --- | --- |
| 40,180 / 1.9 | 0.9051 | 66.12 | 22.60 |
| 40,270 / 1.9 | 0.9318 | 49.55 | 30.40 |
| 40,390 / 1.9 | 0.9509 | 37.53 | 39.70 |

These results demonstrate that vector query performance can be practical and predictable on a single machine, even at billion scale.

## Summary

VectorChord 1.0.0 demonstrates that real-time vector search can scale cleanly from 1 million to 1 billion vectors without forcing users to change architecture, workflows, or usage patterns. Whether you are building image search, AI-powered applications, or RAG pipelines, VectorChord is designed to be a reliable vector engine that runs on your own machine and scales naturally as your data grows.

Ready to scale up? You can get started today, or reach out on [GitHub](https://github.com/tensorchord/VectorChord) or [Discord](https://discord.gg/KqswhpVgdU) to learn more and get support from the community.
