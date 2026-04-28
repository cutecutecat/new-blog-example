---
title: "VectorChord 1.0"
description: "Developer-first vector search on Postgres with up to 100x faster indexing than pgvector at 100M scale."
author: "vectorchord"
pubDate: 2026-04-27
heroImage: ../../../assets/covers/vectorchord-1-0.svg
---

Two years ago, when we published the very first [pgvecto.rs](https://github.com/tensorchord/pgvecto.rs) blog post, we made a bet: **Postgres is the best place to do vector search**. Since then we've been iterating on that bet, from VBASE with filtered vector search, to longer vector support, to the RaBitQ quantization scheme and disk-friendly index layouts.

With VectorChord 1.0 we're moving the needle again. On a 16 vCPU machine, we can now build an index over 100M vectors in under 20 minutes. On the same scale, pgvector needs more than 50 hours. That number sounds impressive, but the point of this release isn't just to win a benchmark slide. It's to make your **actual** development and iteration loop much faster.

This post is organized into three parts:

1. [Why we chose a simpler IVF + RaBitQ index instead of HNSW, and how that plays much better with Postgres.](#1-simplicity-over-complexity-breaking-the-hnsw-is-always-better-myth)
2. [How we made index build time short enough that you can treat "rebuild" as part of normal iteration, not an overnight job.](#2-making-indexing-feel-like-iteration-not-an-outage)
3. [What we've added around developer experience so VectorChord feels like a developer tool, not just a performance demo.](#3-features-built-for-developers-not-just-for-a-benchmark-chart)

---

## 1. Simplicity over complexity: breaking the "HNSW is always better" myth

When people first talk to us about VectorChord, one of the most common questions is very direct:

> "Are you using HNSW? I heard HNSW is always better than IVF."

On paper, HNSW is a beautiful algorithm. In many isolated benchmarks it wins. But we don't run vector search inside a vacuum, we run it inside Postgres, with its own storage model, vacuuming, MVCC, and operational habits.

If you look at it from that angle, the trade-off changes a lot.

### The Postgres reality of HNSW

HNSW uses a layered graph structure. Every new vector is a node that may connect to several other nodes across multiple layers. Every delete potentially removes a node that many other nodes depend on.

In a stand-alone vector engine you can design the entire storage engine around this structure. Inside Postgres, you can't. You have to live inside the existing table/index model, work with vacuum, and behave well under MVCC.

That's where the pain starts:

- **Insertions are heavy.** Inserting a single vector into an HNSW index can trigger cascades of changes across multiple nodes and layers. Under high write load this makes it harder to keep latency stable.
- **Deletions are subtle.** In practice, a delete often just marks a node as dead but leaves it in the graph so connectivity isn't broken immediately. As more nodes are marked this way, search still walks through them, which adds extra latency when a large fraction of the graph is "dead but still present."
- **Vacuum pays the real price.** You can't simply drop those nodes, because removing them outright would break neighborhoods and disconnect parts of the graph. To fix that, pgvector has to reinsert all the neighbors of a dead node so the graph stays connected without it. That reinsertion work is what makes maintenance expensive; the core issue isn't just reclaiming dead tuples, it's re-wiring the graph around every deleted node.

None of this is impossible, but it pushes you toward high cost whenever you have frequent updates.

### Why we chose IVF + RaBitQ instead

VectorChord's core index is IVF + RaBitQ with simple posting lists. Vectors are routed into coarse clusters, and inside each cluster we store a tiny quantized code instead of a 768-dimensional float. At query time almost all the work happens on these bit-packed codes, using table lookups and cheap integer math.

Because the index mostly scans compressed codes, a posting-list scan stays fast even when it touches many entries. In our benchmarks this makes VectorChord clearly faster than a naive IVF that compares full-precision vectors, and still faster than pgvector's HNSW index, which walks its graph and scores neighbors with full-precision arithmetic.

People sometimes ask "what about HNSW + quantized vectors?" You can do that, and it can speed up the first phase of a search, where you traverse the quantized vectors and pick candidates. But you still need a second phase that fetches and scores full-precision vectors based on those candidates, and that part doesn't care which index you used. In typical workloads the first phase is only about 40% of total latency, so even a 2x faster scan would only cut end-to-end time by roughly 20%, and because HNSW can't lay out data in the tight, batch-friendly fast-scan format, even that theoretical gain may be hard to realize in practice.

With IVF + RaBitQ the postings are just arrays of compressed entries. Inserts append a new code; deletes clear a code. There is no global graph to repair, so frequent updates don't trigger cascades of work. Operationally it behaves like a normal index, and in our tests this design handles around 10x the update throughput of pgvector's HNSW index while keeping latency stable. For additional performance numbers, especially around query performance, please see our earlier blog [**Vector Search Over PostgreSQL: A Comparative Analysis of Memory and Disk Solutions**](https://blog.vectorchord.ai/vector-search-over-postgresql-a-comparative-analysis-of-memory-and-disk-solutions).

Most importantly, this simplicity is what enables the improvements in the next sections. If your index structure is already incredibly intricate, every extra optimization adds more moving parts. By keeping the core design simpler, we gave ourselves room to make **index builds** and **developer workflows** dramatically better.

---

## 2. Making indexing feel like iteration, not an outage

Let's talk about the number in the title: **100x faster indexing than pgvector**.

On paper, the comparison looks like this on LAION 100M-vector dataset:

- pgvector: more than 50 hours of index build time on 16 vCPUs (and it may fail if memory is insufficient).
- VectorChord 0.1: KMeans done externally in about 2 hours on a GPU; insertion in Postgres taking around 20 hours on 4 vCPUs.
- VectorChord 1.0: KMeans and insertion both done inside Postgres, finishing in under 20 minutes on 16 vCPUs (about 8 minutes for KMeans + 12 minutes for insertion).

But what changes for you is much simpler:

- In the pgvector world, indexing a large dataset is a **multi-day event**. You plan around it, you babysit it, you worry about what happens if it fails.
- In the VectorChord 1.0 world, a full rebuild is closer to **"run it before lunch and check the results after coffee."**

We got there by attacking both phases of IVF building: the KMeans step that finds centroids, and the insertion step that assigns every vector to its nearest centroid.

To get there, we tackled the problem instead of just the code. First, instead of micro-optimizing a naive 768-dimensional, 160,000-centroid KMeans over 100M points, we project vectors down to a much smaller space with Johnson-Lindenstrauss Lemma, which cuts the KMeans compute and memory footprint by roughly 7x. Second, we run hierarchical KMeans in two stages so we only ever cluster smaller subsets of the data instead of 160,000 centroids at once, which accelerates 400x in theory. For insertion, we reuse the same idea one level up by building an IVF over the centroids themselves, so each data vector only compares against a small set of candidate centroid buckets using quantized codes. Together these changes move most of the work out of CPU-bound distance math: for a 100M-vector build the dominant cost becomes Postgres allocating and writing index pages at roughly the SSD limit. After tightening the allocation path and lock granularity so we can stream pages out in large chunks, the practical result is that a full rebuild fits comfortably into minutes instead of days. For more details, we've written a dedicated blog [**How We Made 100M Vector Indexing in 20 Minutes Possible on PostgreSQL**](https://blog.vectorchord.ai/how-we-made-100m-vector-indexing-in-20-minutes-possible-on-postgresql) to explain the technical detail.

These optimizations can be done easily with the following SQL:

```sql
CREATE INDEX ON laion USING vchordrq (embedding vector_l2_ops) WITH (options = $$
build.pin = 2
[build.internal]
lists = [400, 160000]        -- Hierarchical KMeans
build_threads = 16
spherical_centroids = true
kmeans_algorithm.hierarchical = {}
kmeans_dimension = 100 -- Dimension Reduction
sampling_factor = 32
$$);
```

---

## 3. Features built for developers, not just for a benchmark chart

VectorChord 1.0 also adds a set of features that barely show up in benchmarks, but matter a lot when you live with the system every day. They're all about helping you understand how your index behaves, and about letting you use modern models and deployments without friction.

### Built-in monitoring of index quality

All approximate nearest-neighbor indexes drift over time. Data distributions change, and what was a great index at build time might quietly degrade.

Instead of leaving you to guess, VectorChord can continuously measure recall for you. It automatically samples real query vectors, re-evaluates their neighbors with a more exact method, and tracks how often the index returns the "right" answers.

This turns a vague feeling, "search seems a bit off lately," into a graph you can look at. If recall is steady, you know you can postpone a rebuild. If it's trending down, you can plan a rebuild before users notice. It also gives you something concrete to feed into your existing observability stack, or into Prometheus so you can keep an eye on recall on the same dashboards as your other SLOs.

In practice, you can evaluate recall for a real query pattern with a single SQL call, and then export that number as a metric. For example:

```sql
SELECT vchordrq_evaluate_query_recall(query => $$
  SELECT ctid FROM items ORDER BY embedding <-> '[3,1,2]' LIMIT 10
$$);
-- With sampled vector recorded from query
SELECT AVG(recall_value) FROM (
    SELECT vchordrq_evaluate_query_recall(
            format(
                'SELECT ctid FROM %I.%I ORDER BY %I OPERATOR(%s) %L LIMIT 10',
                lq.schema_name,
                lq.table_name,
                lq.column_name,
                lq.operator,
                lq.value
            )
    ) AS recall_value
    FROM vchordrq_sampled_queries('items_embedding_idx') AS lq
) AS eval_results;
```

### Long vector support so you don't have to cripple your model

We support vectors up to 16,000 dimensions. That sounds like a dry specification, but it has a clear practical effect: you can plug in newer models, including long-context or multimodal ones, without immediately needing to compress or truncate their outputs just to make the index happy.

You can start with the representation your model naturally produces, get a feel for performance and quality, and then decide whether you want to apply more aggressive quantization or dimensionality reduction. The index shouldn't be the thing forcing you to compromise on model choice.

### Multi-vector retrieval for richer RAG

Not every document fits into a single vector. Modern retrieval-augmented generation (RAG) systems often represent a passage as a *set* of vectors, for example, one per token or one per sentence, and then compare that set to a set of query vectors. This "late interaction" style is usually called multi-vector retrieval.

VectorChord supports this pattern natively via a MaxSim-style operator over arrays of vectors. Conceptually, for each query vector you look for the best-matching document vector, take their dot product, and then sum those best scores. In VectorChord this is exposed as the distance-based `@#` operator on `vector[]` columns: the left-hand side is the document's vector array, the right-hand side is the query's vector array.

Getting started looks very similar to single-vector search. You store an array of vectors per row and build a dedicated index:

```sql
CREATE TABLE items (
  id         bigserial PRIMARY KEY,
  embeddings vector(3)[]
);

CREATE INDEX ON items
USING vchordrq (embeddings vector_maxsim_ops);
```

At query time you pass in an array of query vectors and order by the `@#` score:

```sql
SELECT *
FROM items
ORDER BY embeddings @# ARRAY[
  '[3,1,2]'::vector,
  '[2,2,2]'::vector
]
LIMIT 5;
```

Under the hood VectorChord applies its ANN machinery to these vector arrays, so you get the expressiveness of multi-vector models with the same kind of performance you expect from single-vector IVF indexes, all inside Postgres and plain SQL.

### Multi-platform SIMD

VectorChord ships with SIMD acceleration for x86_64, ARM and IBM architectures. At runtime we detect the best available instruction set, AVX512 and friends where available, and use it without you having to tune build flags or keep separate binaries.

### Experimental DiskANN + RaBitQ

We also have an experimental index type combining DiskANN with 2-bit RaBitQ. On some datasets and recall targets it can deliver higher QPS than IVF + RaBitQ. The trade-off is that indexing and updates are noticeably slower and more complex.

```sql
CREATE INDEX ON items USING vchordg (embedding vector_l2_ops);
```

We don't recommend this as the default choice. It's there for teams who have very specific workloads, know exactly what they are doing, and are willing to pay higher operational costs for more QPS in a narrow slice of the parameter space. For everyone else, IVF + RaBitQ remains the recommended workhorse.

### Similarity filters that stop scanning early

Sometimes you don't just want the nearest neighbors; you want "everything within this radius, up to N rows." The most natural way to write that in SQL is with a distance in the `WHERE` clause, plus `ORDER BY` and `LIMIT`:

```sql
SELECT *
FROM items
WHERE embedding <-> '[0,0,0]' < 0.1
ORDER BY embedding <-> '[0,0,0]'
LIMIT 10;
```

This returns the right answers, but it performs poorly when only a few points fall inside the radius. Postgres still has to keep scanning the index until it finds ten rows or exhausts the search space, because the distance check is just a filter applied after the ANN scan.

VectorChord adds a "similarity filter" syntax that lets the distance threshold be pushed down into the index itself. You wrap the query vector and radius in a `sphere()` value, and use the `<<->>` operator so the index knows it can stop as soon as the search region moves beyond that sphere:

```sql
SELECT *
FROM items
WHERE embedding <<->> sphere('[0,0,0]'::vector, 0.1)
ORDER BY embedding <-> '[0,0,0]'
LIMIT 10;
```

### Prefilter and postfilter so queries match your data model

In real applications, vector search almost never happens in isolation. You filter by tenant, permissions, time ranges, or content type, then rank by vector similarity, or sometimes the other way around.

VectorChord lets you choose between prefiltering and postfiltering at the index level. In low-selectivity scenarios, prefiltering can reduce the candidate set enough to get up to roughly five-fold QPS improvements. In other cases you might want to search first and filter only the top results for better recall. The important part is that you can express both patterns naturally in Postgres.

Enabling prefiltering for a session is a single SQL statement:

```sql
SET vchordrq.prefilter = on;
```

### Text search with VectorChord-BM25

Finally, we added a VectorChord-BM25 extension that brings strong text search directly into your Postgres instance. It supports multiple languages and advanced tokenization, and aims to be competitive with ElasticSearch-style relevance for many workloads.

The idea is not to replace every dedicated search engine, but to let you build systems where BM25 and vector search live side by side, inside the same database, using the same operational tools. For many teams that alone removes a lot of deployment and maintenance burden.

In practice you can call it from plain SQL, combine it with your embeddings, and order by a unified score. For example:

```sql
SELECT id,
       passage,
       embedding <&> to_bm25query('documents_embedding_bm25', tokenize('PostgreSQL', 'bert')) AS rank
FROM documents
ORDER BY rank
LIMIT 10;
```

---

## Closing thoughts

VectorChord 1.0 is easy to summarize as "100x faster indexing than pgvector on 100M vectors." That headline is true, but it is not the main story.

Our goal is to make VectorChord one of the best ways to do retrieval on Postgres, from the first prototype to billion-scale datasets. If you're already using pgvector, we'd love you to try VectorChord 1.0 on your real workloads and tell us where it helps and where it can do better. We would also like to express our appreciation to the EnterpriseDB team for their valuable feedback throughout this work.
