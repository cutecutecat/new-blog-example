---
title: "How We Made 100M Vector Indexing in 20 Minutes on PostgreSQL"
description: "VectorChord 1.0 optimizations that cut 100M-vector index build time to 20 minutes and reduce memory usage by 7x on CPU-only instances."
author: "vectorchord"
date: 2026-04-27
heroImage: /images/covers/vectorchord-100m-indexing-20-minutes.svg
---

## 1. Introduction

In the past few months, we’ve heard consistent feedback from users and partners: while our goal of providing a scalable, high-performance alternative to pgvector is well-received, index build time and memory usage remain major concerns at billion-scale.

Now VectorChord can index 100 million 768-dimensional vectors in 20 minutes on a 16 vCPU machine with just 12 GB of memory. By contrast, indexing the same data with pgvector requires around 200 GB of memory and about 40 hours on a 16-core instance. And pgvector with insufficient memory often suffer from page swapping, making builds even slower.

In short, memory usage and build time have become the key barriers to large-scale deployment of vectors. Through a series of targeted optimizations, we reduced build time to **20 minutes** and memory usage by **7x**, with only minor accuracy trade-offs.

With these improvements, we can now use far cheaper machines with much less memory, without a GPU, **while still hosting 100 million 768-dimensional vectors**:

|  | Instance | Price | Memory used / total |
| --- | --- | --- | --- |
| Previous minimum | Amazon i7i.8xlarge | 🟨 $2174 monthly | 135 GB / 256 GB |
| Recommend for faster indexing | Amazon i7i.4xlarge | ✅ $**1087** monthly | 12 GB / 128 GB |
| Minimum | Amazon i7i.xlarge + GPU for indexing | ✅ $**272** monthly + GPU cost | 6 GB / 32 GB |

In the following sections, we will introduce how we optimized these phases to make index building faster and more memory-efficient. The optimizations are organized as follows: one targets each phase.

| Optimization | Target phase | Result |
| --- | --- | --- |
| [Hierarchical K-means](#hierarchical-k-means) + [Dimensionality Reduction](#dimensionality-reduction) | 1 Initialization | 30 min (GPU) -> 8 min (CPU), 135 -> 23 GB |
| [Reducing Contention](#4-reducing-contention) | 2 Insertion | 420 min -> 9 min |
| [Parallelize Compaction](#5-parallelize-compaction) | 3 Compaction | 8 min -> 1 min |

## 2. Background

The index type used in VectorChord, **vchordrq** is logically a tree of height \(n+1\). The first \(n\) levels of the tree are immutable which serve purely as the routing structure for search. The \((n+1)\)-th level stores all data.

If \(n=1\), the index is a flat, non-partitioned structure. If \(n=2\), it is an inverted file index. If \(n=3\), it has an additional layer.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1764057309344/ab2bc34f-0185-4513-bdf6-ff82c91db0c4.webp)

The index building can be divided into 3 phases: **Initialization**, **insertion** and **compaction**.

- **Initialization Phase**
  In this phase, top \(n\) levels of the tree are written to the index. Firstly, the index samples vectors in the table. Then the index builds the tree by clustering the samples, the centroids, the centroids of centroids, and so on for \(n\) levels. Finally the tree is written to the index.
- **Insertion Phase**
  The index inserts vectors from the table into the bottom level of the tree.
- **Compaction Phase**
  The index converts all the inserted vectors from non-compact layout to compact layout.

## 3. Making Clustering Faster and More Memory-efficient

In the past, although we can build index for 100 million vectors on small instances, it typically needs a GPU to accelerate clustering.

The main bottleneck in the initialization phase is clustering, which is time-consuming and memory-intensive. In fact, it decides the minimum memory requirement of index building. If we implement clustering on the CPU in a way that is both fast and memory-efficient, it would be practical to build indexes on small instances without large memory and GPUs.

Let \(n\) be the number of vectors, \(c\) be the number of centroids, \(d\) be the dimension of vectors, and \(l\) be the number of iterations. The time complexity of K-means is \(O(ncdl)\), and the space complexity of it is \(O(nd + cd)\). Let \(f\) be the sampling factor, in other words, \(n=fc\). The time complexity of K-means is \(O(fc^2dl)\), and the space complexity of it is \(O(fcd)\).

In the following sections, we will explain how to reduce the complexity, as well as decrease \(d\) and \(f\) for better performance.

### Hierarchical K-means

Constrained by time complexity, K-means cannot be improved beyond linear speedup, regardless of the optimizations applied. Even on a GPU, this would take 30 minutes. So we must reduce time complexity.

A simple idea is to divide the samples to multiple disjoint subsets, run K-means on every subset, and then merge the centroids on every subset. To balance the size of these subsets and the number of them, we choose \(\sqrt{c}\) as the number of subsets. In order to generate \(\sqrt{c}\) subsets, we initially perform a small-scale K-means and then assign the \(n\) vectors to \(\sqrt{c}\) disjoint subsets using \(\sqrt{c}\) centroids.

Assuming the subsets are of uniform size, the time complexity of this step is \(O(f\sqrt{c}\sqrt{c}dl) \times \sqrt{c} = O(fc^{1.5}dl)\). If `f = 64` and `c = 160,000`, the algorithm would be roughly 400 times faster.

There is still a small problem here. How many centroids should be computed for a subset? If we ignore the constraint that it must be an integer, it's \(\frac{n}{|s|}c\). Considering this constraint, this problem is similar to proportional representation, where [Sainte-Lague method](https://en.wikipedia.org/wiki/Sainte-Lagu%C3%AB_method) is an algorithm that minimizes the average seats-to-votes ratio deviation. It works as follows.

> After all the votes have been tallied, successive quotients are calculated for each party. The formula for the quotient is \(\frac{V}{s_i+0.5}\), where \(V\) is the total number of votes that party received, and \(s_i\) is the number of seats that have been allocated so far to that party, initially \(0\) for all parties.

Now clustering on CPU is practical. However, this algorithm does not reduce memory usage.

### Dimensionality Reduction

It’s time to review the 140 GB of memory used for K-means samples. It would definitely result in OOM on a machine with memory of 128 GB. Consider the space complexity \(O(fcd)\), we have two ways to reduce memory usage: reduce \(f\), and reduce \(d\).

Let's reduce \(d\) now. Although it sounds incredible, we can first reduce the dimension of the vectors and then perform clustering without compromising accuracy. [Christos’s results](https://arxiv.org/abs/1011.4632) show that running K-means on low-dimensional projections can still maintain good accuracy.

> [Johnson-Lindenstrauss lemma](https://en.wikipedia.org/wiki/Johnson%E2%80%93Lindenstrauss_lemma) states that a set of points in a high-dimensional space can be embedded into a space of much lower dimension in such a way that distances between the points are nearly preserved. In the classical proof of the lemma, the embedding is a random orthogonal projection.

According to the theorem, \(n\) vectors can be reduced to \(O(\lg n)\) dimensions. Specifically, we only need to construct a random Gaussian matrix, which allows us to reduce high-dimensional vectors to low-dimensional ones using matrix multiplication. Then we perform K-means on it.

Since we need to reduce memory usage, we apply the Johnson-Lindenstrauss transform directly during sampling. In the end, we obtain low-dimensional centroids. We do not attempt to perform an inverse transform; instead, we sample from the table again, find the nearest cluster in the low-dimensional space after the Johnson-Lindenstrauss transform, and thereby recover the high-dimensional centroids.

With dimensionality reduction from 768 to 100, the resident set size of the instance dropped to 23 GB, allowing us to build the index on an i4i.xlarge instance. Additionally, this also results in clustering being 7 times faster, in theory. With hierarchical K-means and dimensionality reduction, the time of initialization phase fell to 24 minutes.

Reducing \(f\) is trivial. It's configured as `build.internal.sampling_factor` so we only need to change the configuration. Let's set \(f\) to \(64\). The resident set size of the instance dropped to 6 GB, and clustering is roughly 2 times faster.

### Sampling

In order to perform clustering, we need to sample vectors from the table. Our previous approach, [reservoir sampling](https://en.wikipedia.org/wiki/Reservoir_sampling) was reliable but slow. This method is used because we do not know the number of rows in the table without doing a full table scan. However, it would still perform a full table scan.

To avoid a full table scan, we take advantage of PostgreSQL table access method's sampling interface. The interface takes a function that, given the maximum block number, produces an iterator of block numbers. The interface then returns an iterator over the tuples in those blocks. In order to generate such a random iterator, we can generate an ordered sequence and perform [Fisher-Yates shuffle](https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle) on it, but this consumes memory. In fact, we have a more clever approach. In cryptography, a [pseudorandom permutation](https://en.wikipedia.org/wiki/Pseudorandom_permutation) is a function that cannot be distinguished from a random permutation.

[Feistel network](https://en.wikipedia.org/wiki/Feistel_cipher) could be used as a pseudorandom permutation. It defines as \(L_{i + 1} = R_{i}, R_{i + 1} = L_{i} \oplus F(R_i, K_i)\), where \(F\) is a hash function, \(K_i\) is the random seed. The input of the function is \((L_0, R_0)\), and the output of the function is \((L_n, R_n)\). So it's a function from \([0, 2^n) \times [0, 2^n)\) to \([0, 2^n) \times [0, 2^n)\). Cleverly, because of \(R_{i} = L_{i + 1}, L_{i} = R_{i + 1} \oplus F(L_{i + 1}, K_i)\), this function is reversible. A reversible function is bijective, so this function is bijective. \([0, 2^n) \times [0, 2^n)\) is equivalent to \([0, 4^n)\), and therefore it's a permutation of \([0, 4^n)\). Now, by filtering out all elements greater than the maximum block number from this permutation, we get the lazy random permutation we need.

Based on the interface and this function, we implement block sampling, which only needs to access the sampled vectors.

With all these optimizations, the initialization phase takes only 8 minutes in total now.

## 4. Reducing Contention

In earlier experiments, building the index for the `LAION-100m` dataset on an Amazon i7i.16xlarge (64 vCPU) instance takes approximately 420 minutes during the insertion phase if \(n=2\) is used, and this is entirely computation-bound.

Starting with version 0.1, VectorChord allows \(n\) to be set to a positive integer no greater than \(8\). From our perspective, it is necessary for billion-scale data. However, at that time, we didn't actually know how much fast it would be.

After trying \(n=3\) on a smaller instance, i7i.4xlarge (16 vCPU), we observed that the insertion phase completed in just 40-60 minutes. At that point, CPU utilization stayed around 40%, and IO throughput fluctuated between 300 MB/s and 800 MB/s, suggesting a large room for optimization.

### Reducing Linked-List Contention

The insertion phase took 40-60 minutes. Surprisingly, our tests showed that 8 workers took 40 minutes, while 16 workers took 55 minutes. This suggests the existence of potential contention among workers during insertion.

In the implementation, the index maintains a single linked list to store full-precision vectors aside from the tree, while the tree only stores quantized vectors. This makes the tree nodes much smaller and allows the tree to fit in memory.

Since changing \(n\) from \(2\) to \(3\), the number of computations of insertion phase has decreased. As a result, inserting vectors into this linked list occurs much more frequently. Parallel workers experience contention when inserting into the list. So more workers actually slow down the insertion, making the performance unpredictable.

To address this, we replaced the single linked list with \(1+k\) linked lists. The first linked list stores full-precision vectors for the top \(n\) levels of the tree, while the other \(k\) lists store vectors for the bottom level. During index build, the \(i\)-th worker inserts vectors into the \((i \text{ mod } k)\)-th list. We set \(k=32\) as the default, and consider it sufficient for most cases.

With this change, CPU utilization stabilizes around 54%, and the insertion phase now completes in about 30 minutes.

### Reducing Page Extension Lock Contention

The CPU utilization still suggested that more optimizations were potential. But where exactly was the bottleneck? We started our investigation by checking PostgreSQL worker processes using `htop`.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1764296302226/4ac9364b-09d9-4a13-81b7-dc2252b800b6.png)

Many processes showed `waiting` on their titles, indicating heavy internal contention inside PostgreSQL. Searching in the code, we traced the source that sets `waiting` to [lock.c](https://github.com/postgres/postgres/blob/REL_18_0/src/backend/storage/lmgr/lock.c#L1943). To measure off-CPU time, we turned to offcputime from [BCC](https://github.com/iovisor/bcc). Then, with `stackcollapse.pl` and `flamegraph.pl` from Brendan Gregg's [FlameGraph](https://github.com/brendangregg/FlameGraph), we generated a flame graph for the process's off-CPU time.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1764294200682/6c64c880-2083-4c73-bf1e-65a10b61c77e.png)

The result was surprising: the culprit was `LockRelationForExtension`, which acquired the lock of the index for extending it.

> Here, the `ockRelationForExtension` should be `LockRelationForExtension`. This may be result from an unknown behavior from the `flamegraph.pl` script.

Why does acquiring this lock become a bottleneck? Searching through the PostgreSQL mailing list led us to this [discussion](https://postgr.es/m/20221029025420.eplyow6k7tgu6he3@awork3.anarazel.de).

In short, PostgreSQL places a lock on each index to prevent this index from being extended concurrently. But the granularity of this lock is too coarse. Thanks to Andres Freund, a patch was introduced that narrows the critical section and fixes the issue, but it requires the new API available since PostgreSQL 16.

Since VectorChord supports PostgreSQL 13 through 18, we took advantage of the old API in the early development. Unfortunately, that meant we overlooked this optimization.

After switching to the new API, the insertion phase dropped to 22 minutes.

### Bulk Page Extensions

However, another round of profiling revealed that the bottleneck remains in the same area.

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1764294272317/208f1bcb-ee51-46a0-98b4-9e18257e48a2.png)

As the critical section of the lock is already narrowed, we need to speed up the page extension to ease the bottleneck. Extending a file using `fallocate` is fast on the filesystem. If `fallocate` is used for extending the index, the average time for extending a page will be shorter. So the question becomes: can we use `fallocate` to extend the index?

The answer is yes. If the index is extended more than 8 pages at a time, PostgreSQL automatically switches from `pwrite` to `fallocate`. By requesting 16 pages at once, we significantly increased the speed of page extension.

With this change, the insertion phase dropped to 9 minutes, CPU utilization stabilized at 90%, and write throughput stayed around 1.8 GB/s. `iostat` reported IO utilization of 0.75-0.85, indicating we were finally making better use of the resources.

There is still room for improvement. But for now, there is no longer any trivial bottleneck in the insertion phase.

## 5. Parallelize Compaction

On the bottom level of the tree, quantized vectors exist in two layouts:

- Non-compact layout (insert-oriented): Every quantized vector is stored as a tuple, so data can be appended directly without modifying existing tuples.
- Compact layout (search-oriented): Every 32 quantized vectors are stored as a tuple. It's optimized for SIMD and makes the search fast.

All vectors are initially inserted in the non-compact layout, and will be converted into the compact layout in the final phase. It is worth noting that this phase is serial and takes about 8 minutes during index build.

Since the other phases have become much faster, optimizing this phase has become more important. So we parallelize this phase. If there are \(k\) workers, and \(m\) nodes in the level \(n\) of the tree, the children of the \(i\)-th node will be compacted by the \((i \text{ mod } k)\)-th worker. Benefiting from parallelism, the compaction phase now takes less than 1 minute.

You may notice that an effective index also requires this compaction occasionally to maintain search performance. PostgreSQL has a vacuum mechanism for this purpose. So this phase is also performed for the indexes routinely in vacuum. Unfortunately, we cannot parallelize it in vacuum: PostgreSQL does not allow an index to use nested parallelism. If the vacuum is parallel, the index could not start parallel workers again.

## 6. Conclusion

Previously, indexing the `LAION-100M` dataset with VectorChord `0.5.3` on an Amazon i7i.4xlarge instance was infeasible due to out-of-memory (OOM) failures. [Offloading clustering to a GPU](https://docs.vectorchord.ai/vectorchord/usage/external-index-precomputation.html) made the build possible, yielding a recall of **95.6%** at **120** QPS for querying the top 10 results, with a build time of **30 minutes** on the GPU and **420 minutes** on the i7i.4xlarge.

With the optimizations introduced in VectorChord `1.0.0`, the index can now be built entirely on the i7i.4xlarge instance in only **18 minutes**, achieving a recall of **94.9%** under the same QPS setting.

```pgsql
CREATE INDEX ON laion USING vchordrq (embedding vector_ip_ops) WITH (options = $$
build.pin = 2
[build.internal]
lists = [400, 160000]
build_threads = 16
spherical_centroids = true
kmeans_algorithm.hierarchical = {}
kmeans_dimension = 100
sampling_factor = 64
$$);
```

Our goal is to make VectorChord one of the best ways to do retrieval on PostgreSQL, from the first prototype to billion-scale datasets. If you’re already using pgvector, we’d love you to try VectorChord 1.0 on your real workloads and tell us where it helps and where it can do better.
