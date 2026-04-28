---
title: "VectorChord 0.4"
description: "Major upgrades for disk-bound query I/O and filtered vector search, with big latency and throughput wins."
author: "vectorchord"
pubDate: 2025-06-05
heroImage: ../../../assets/covers/vectorchord-0-4.svg
---

We're excited to announce the release of **VectorChord 0.4**, a significant update that enhances high-performance vector search within PostgreSQL. We believe this release pushes the boundaries of what's possible for vector search in PostgreSQL, introducing key architectural improvements designed to lower latency and increase throughput for demanding, real-world workloads.

If you're working with similarity searches, RAG pipelines, or other AI-driven applications on PostgreSQL, these updates are for you. We've focused on two major areas: significantly enhancing I/O for cold queries by leveraging PostgreSQL's evolving capabilities, and optimizing filtered vector searches.

## Major Improvement 1: Advanced I/O for Disk-Bound Indexes (2x-3x Lower Cold Query Latency)

![Async I/O figure](https://cdn.hashnode.com/res/hashnode/image/upload/v1749113884459/3282ee41-625d-4b8a-9373-8b2eb8d81f1c.png)

VectorChord has supported **disk-based indexing** since its early versions. Previously, a challenge was I/O efficiency, as full-precision vectors were read one-by-one due to **limitations in PostgreSQL's older internal APIs for buffer operations**.

VectorChord 0.4 addresses this with a **rewritten page layout** and the adoption of **modern streaming I/O techniques**. We're proud to be **one of the first, if not the first, PostgreSQL extensions to adopt these new streaming I/O APIs** as they become available. This allows us to pipeline I/O with computation and issue disk I/O operations more effectively.

As a part of this effort, we've also **contributed initial PostgreSQL 18 support to the `pgrx` framework** to enable testing and development with these upcoming AIO capabilities, benefiting the wider PostgreSQL community.

Our approach adapts to your PostgreSQL version:

- **On PostgreSQL 17 (and newer with `io_method=sync`)**: utilizing `madvise` for prefetching. When VectorChord calls PostgreSQL's new streaming I/O APIs, PostgreSQL's underlying implementation on PG17 (or PG18 with `io_method=sync`) may internally use `madvise(MADV_WILLNEED)`. This hints the OS kernel about upcoming data needs, enabling reads from disk to be cached in memory first. When actual I/O occurs, PostgreSQL can read directly from the page cache instead of waiting for disk I/O.
- **Preparing for asynchronous I/O on PostgreSQL 18 with `io_uring`**: VectorChord 0.4 is engineered for integration. This will allow data to be fetched directly into PostgreSQL's shared buffers with minimal overhead and maximal efficiency.
- **For earlier PostgreSQL versions (pre-PG17)**: we've implemented a similar streaming I/O interface within VectorChord for backward compatibility. While it doesn't leverage kernel-level AIO or the newest PostgreSQL internal APIs, this interface allows effective prefetching of buffers so users on earlier PostgreSQL versions can still benefit from improved I/O patterns and reduced latency when fetching full-precision vectors.

**Impact:** these I/O enhancements result in a **2x-3x reduction in latency for cold queries** in our benchmarks. This directly improves tail latency, especially when queries require re-ranking with disk-resident vectors.

![Streaming I/O benchmark](https://cdn.hashnode.com/res/hashnode/image/upload/v1749113962813/e201cce3-2096-40c8-b318-95a1863e9e47.png)

## Major Improvement 2: Pre-filtering for Faster Filtered Searches (Up to 3x Faster)

![Prefilter comparison](https://cdn.hashnode.com/res/hashnode/image/upload/v1749113999755/aaf3b1f5-8289-4a15-9545-774dd9b3b954.png)

Vector search is often combined with metadata filtering. Addressing this efficiently has been a key focus for us. We were among the **first to tackle the vector filtering challenge in PostgreSQL by introducing VBASE-style filtering** in pgvecto.rs, which significantly improved performance over pgvector.

Now, with VectorChord 0.4, we're **pushing performance to the next level by introducing robust prefiltering support**.

- **Post-filtering (previous method)**: find top-K vectors, then filter. This is inefficient for selective filters.
- **Pre-filtering (new in 0.4)**: based on bit-vector scan results, identify rows satisfying metadata filters first, then perform vector distance calculations only on this smaller set.

We now use efficient mechanisms with quantized bit-vector scans to identify matching rows *before* vector distance computations. Since filter checks are much lighter than distance calculations, this provides a significant speedup. You can enable this with:

```sql
SET vchordrq.prefilter = ON;
```

**Impact:** our benchmarks show **up to 3x faster search performance** when pre-filtering is applicable, compared to our already optimized VBASE post-filtering approach.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1749114043805/f1fbd015-c96e-4a22-8c20-bb249cd5ba24.png)

## Other Notable Improvements

- **Optimized residual quantization (~20% QPS boost):** thanks to Jianyang (author of RaBitQ), we've refined residual quantization. By reformulating `<o, q-c>` as `<o, q> - <o, c>`, the query vector `q` is quantized only once, yielding a **~20% QPS improvement**. We now recommend enabling residual quantization for L2 distance.
- **Optimized rotation matrix and simplified configuration:** also thanks to Jianyang, a new Fast Hadamard Transform optimizes rotation matrices and removes the `prewarm_dim` GUC, simplifying configuration and slightly improving performance.
- **Rewritten documentation:** we've comprehensively rewritten our documentation and now offer **more user guidance and a detailed API reference**. Check <https://docs.vectorchord.ai/vectorchord/>.

## Get Started with VectorChord 0.4

We believe this release significantly enhances vector search capabilities in PostgreSQL.

- **Download/Star on GitHub:** <https://github.com/tensorchord/VectorChord>
- **Join the Community:** <https://discord.gg/KqswhpVgdU>

We encourage you to try VectorChord 0.4, benchmark it with your workloads, and share your feedback.

Happy Vector Searching!
