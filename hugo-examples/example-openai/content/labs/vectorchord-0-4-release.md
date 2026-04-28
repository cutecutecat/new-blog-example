---
title: "VectorChord 0.4 Release: Faster Disk I/O, Smarter Filtering, and Better Throughput"
description: "VectorChord 0.4 introduces advanced streaming I/O for disk-bound indexes, robust pre-filtering, and multiple performance optimizations for PostgreSQL vector search."
author: "vectorchord"
date: 2026-04-27
heroImage: /images/covers/vectorchord-0-4-release.svg
---

We're excited to announce the release of **VectorChord 0.4**, a significant update that enhances high-performance vector search within PostgreSQL. We believe this release pushes the boundaries of what's possible for vector search in PostgreSQL, introducing key architectural improvements designed to lower latency and increase throughput for demanding, real-world workloads.

If you're working with similarity searches, RAG pipelines, or other AI-driven applications on PostgreSQL, these updates are for you. We've focused on two major areas: significantly enhancing I/O for cold queries by leveraging PostgreSQL's evolving capabilities, and optimizing filtered vector searches.

### Major Improvement 1: Advanced I/O for Disk-Bound Indexes (2x-3x Lower Cold Query Latency!)

![async i/o figure](https://cdn.hashnode.com/res/hashnode/image/upload/v1749113884459/3282ee41-625d-4b8a-9373-8b2eb8d81f1c.png)

VectorChord has supported **disk-based indexing** since its early versions. Previously, a challenge was I/O efficiency, as full-precision vectors were read one-by-one due to **limitations in PostgreSQL's older internal APIs for buffer operations**.

VectorChord 0.4 addresses this with a **rewritten page layout** and the adoption of **modern streaming I/O techniques.** We're proud to be **one of the first, if not the first, PostgreSQL extensions to adopt these new streaming I/O APIs** as they become available. This allows us to pipeline I/O with computation and issue disk I/O operations more effectively. As a part of this effort, we've also **contributed initial PostgreSQL 18 support to the** `pgrx` framework to enable testing and development with these upcoming AIO capabilities, benefiting the wider PostgreSQL community.

Our approach adapts to your PostgreSQL version:

- **On PostgreSQL 17 (and newer with** `io_method=sync`): Utilizing `madvise` for Prefetching. When VectorChord calls PostgreSQL's new streaming I/O APIs, PostgreSQL's underlying implementation on PG17 (or PG18 with `io_method=sync`) may internally use `madvise(MADV_WILLNEED)`. This hints the OS kernel about upcoming data needs, enabling reads from disk to be cached in memory with page cache first. When actual I/O occurs, PostgreSQL can read directly from the page cache instead of waiting for disk I/O.
- **Preparing for Asynchronous I/O: PostgreSQL 18 &** `io_uring`. Looking ahead to PostgreSQL 18's true Asynchronous I/O (AIO) with `io_uring`, VectorChord 0.4 is engineered for integration. This will allow data to be fetched directly into PostgreSQL's shared buffers with minimal overhead and maximal efficiency.
- **For Earlier PostgreSQL Versions (Pre-PG17): Streaming I/O Interface for Prefetching.** For users on older PostgreSQL versions, we've **implemented a similar streaming I/O interface within VectorChord for backward compatibility.** While it doesn't leverage kernel-level AIO or the newest PostgreSQL internal APIs, this interface allows us to achieve effective prefetching of buffers. This means users on earlier PostgreSQL versions can also benefit from the improved I/O patterns and reduced latency when fetching full-precision vectors.

**The Impact of Advanced I/O for Disk Indexes:** These I/O enhancements result in a **2x-3x reduction in latency for cold queries** in our benchmarks. This directly improves tail latency, especially when queries require re-ranking with disk-resident vectors.

![Streaming I/O benchmark](https://cdn.hashnode.com/res/hashnode/image/upload/v1749113962813/e201cce3-2096-40c8-b318-95a1863e9e47.png)

### Major Improvement 2: Pre-filtering for Faster Filtered Searches (Up to 3x Faster!)

![prefilter comparison](https://cdn.hashnode.com/res/hashnode/image/upload/v1749113999755/aaf3b1f5-8289-4a15-9545-774dd9b3b954.png)

Vector search is often combined with metadata filtering. Addressing this efficiently has been a key focus for us. We were among the **first to tackle the vector filtering challenge in PostgreSQL by introducing VBASE-style filtering** in pgvecto.rs, which significantly improved performance over pgvector.

Now, with VectorChord 0.4, we're **pushing the performance to the next level by introducing robust prefiltering support.**

- **Post-filtering (Previous Method):** Find top-K vectors, then filter. Inefficient for selective filters.
- **Pre-filtering (New in 0.4):** Based on bit vector scan results, identify rows satisfying metadata filters *first*, then perform vector distance calculations only on this smaller set.

We now use efficient mechanisms with quantized bit-vector scans to identify matching rows *before* vector distance computations. Since filter checks are much lighter than distance calculations, this provides a significant speedup. Users can enable this with `SET vchordrq.prefilter=ON`.

**The Impact:** Our benchmarks show **up to 3x faster search performance** when pre-filtering is applicable, compared to our already optimized VBASE post-filtering approach. This offers considerable advantages for complex queries.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1749114043805/f1fbd015-c96e-4a22-8c20-bb249cd5ba24.png)

### Other Notable Improvements

- **Optimized Residual Quantization (~20% QPS Boost):** Thanks to Jianyang (author of RaBitQ), we've refined residual quantization. By reformulating `<o, q-c>` as `<o, q> - <o, c>`, the query vector `q` is quantized only once, yielding a **~20% QPS improvement**. We now recommend users enable residual quantization for L2 distance.
- **Optimized Rotation Matrix & Simplified Configuration:** Also thanks to Jianyang, a new Fast Hadamard Transform optimizes rotation matrices and removes the `prewarm_dim` GUC, simplifying configuration and slightly speeding up the process.
- **Rewritten Documentation:** We've comprehensively rewritten our documentation, now offering **more user guidance and a detailed API reference** to help you get the most out of VectorChord. Check [https://docs.vectorchord.ai/vectorchord/](https://docs.vectorchord.ai/vectorchord/).

### Get Started with VectorChord 0.4

We believe this release significantly enhances vector search capabilities in PostgreSQL.

- **Download/Star on GitHub:** https://github.com/tensorchord/VectorChord
- **Join the Community:** https://discord.gg/KqswhpVgdU

We encourage you to try VectorChord 0.4, benchmark it with your workloads, and share your feedback.

Happy Vector Searching!
