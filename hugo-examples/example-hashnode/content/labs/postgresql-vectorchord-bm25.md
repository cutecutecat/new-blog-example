---
title: "Improving PostgreSQL Full-Text Search with VectorChord-BM25"
description: "Bring BM25 relevance scoring into PostgreSQL to improve text ranking without adding an external search service."
author: "vectorchord"
date: 2026-04-27
heroImage: /images/covers/postgresql-vectorchord-bm25.svg
---

Modern applications rely on PostgreSQL for its fully ACID-compliant, expressive SQL, and rich ecosystem of extensions. The database handles relational workloads exceptionally well, but many projects also need to search large text collections, such as product descriptions, support tickets, and documentation, and present the most relevant rows first. PostgreSQL's native tools offer a foundation for this, yet their default ranking logic can leave ideal matches buried under less useful results. VectorChord-BM25 changes that equation by introducing the BM25 relevance-scoring algorithm directly into PostgreSQL.

## What is PostgreSQL?

PostgreSQL is an open-source, enterprise-class relational database management system (RDBMS) renowned for reliability, data integrity, and standards compliance. It supports advanced features such as window functions, materialized views, JSONB storage, and a robust extension mechanism that allows developers to add capabilities. Learn more about PostgreSQL [here](https://www.postgresql.org/).

## Full-Text Search with `tsvector`

PostgreSQL has its own tool for basic text search called `tsvector`. Think of it as a special column that stores the important words (lexemes) from each document in a way the database can search quickly. When you add a GIN or GiST index on that column, PostgreSQL can find rows that match a keyword almost instantly. You write searches with the `@@` operator, and the full details are in the PostgreSQL manual [here](https://www.postgresql.org/docs/current/datatype-textsearch.html).

### Where native ranking falls short

While the `ts_rank` function can sort matches, its scoring method is basic. Long documents that mention a term once may outrank short documents focused entirely on the query, and rare but important words carry little extra weight. In large datasets, the perceived relevance of results often suffers.

## What's New: VectorChord Adds BM25

VectorChord-BM25 is a lightweight PostgreSQL extension that augments the existing text-search stack with the industry-standard BM25 ranking formula. Instead of exporting data to an external search engine, you can keep everything inside a single database, gaining:

- Ranking that rewards distinctive terms and penalizes irrelevant verbosity
- In-index scoring, reducing query latency
- Seamless SQL workflow, where documents remain rows and searches remain queries

## What is BM25?

BM25 (Best Matching 25) is a probabilistic retrieval model widely adopted by search engines and academic literature. It evaluates how often a query term appears in a document, how rare that term is across the entire corpus, and how long each document is. The algorithm is discussed in detail on its [Wikipedia page](https://en.wikipedia.org/wiki/Okapi_BM25#:~:text=BM25%20is%20a%20bag%2Dof,slightly%20different%20components%20and%20parameters.), but the core idea is straightforward:

- **Term Frequency (TF)**: More occurrences of a word in a document increase its relevance, but with diminishing returns.
- **Inverse Document Frequency (IDF)**: Rare words are more informative than common ones.
- **Document Length Normalization**: Shorter documents are not unfairly penalized when they focus on the query topic.

VectorChord implements BM25 through a new index type and operator (`<&>`), letting PostgreSQL compute scores while scanning the index.

---

## Two Practical Examples

Below are concise demonstrations that illustrate how to adopt VectorChord-BM25 with a pre-trained tokenizer and, for specialized domains, with a custom model.

### Example 1: Quick Start with a Pre-Trained Model

```bash
# Spin up a pre-configured PostgreSQL instance
docker run --name vchord-suite \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -d tensorchord/vchord-suite:pg17-latest
```

```sql
-- Inside psql
CREATE EXTENSION pg_tokenizer CASCADE;
CREATE EXTENSION vchord_bm25  CASCADE;

-- Register the LLMLingua-2 tokenizer
SELECT create_tokenizer('llm_tok', $$ model = "llmlingua2" $$);

CREATE TABLE articles (
    id   SERIAL PRIMARY KEY,
    body TEXT,
    emb  bm25vector
);

INSERT INTO articles(body) VALUES
('PostgreSQL is a powerful open-source database system.'),
('BM25 is a ranking function used by search engines.');

-- Tokenize each row
UPDATE articles SET emb = tokenize(body, 'llm_tok');

-- Build the BM25 index
CREATE INDEX articles_emb_bm25 ON articles USING bm25 (emb bm25_ops);

-- Query with relevance ordering
SELECT id,
       body,
       emb <&> to_bm25query('articles_emb_bm25',
                            tokenize('open source database', 'llm_tok')) AS score
FROM   articles
ORDER  BY score         -- lower (more negative) = higher relevance
LIMIT  10;
```

The query returns rows already ranked by BM25, producing more intuitive results than the default `ts_rank`.

### Example 2: Custom Model for Domain-Specific Vocabulary

Domain-specific text, such as medical notes, legal briefs, and technical logs, often includes jargon absent from general models. VectorChord lets you train a custom tokenizer directly in SQL.

```sql
-- 1. Create a text analyzer with Unicode segmentation, lowercasing,
--    stop-word removal, and stemming.
SELECT create_text_analyzer('tech_analyzer', $$
pre_tokenizer = "unicode_segmentation"
[[character_filters]]
to_lowercase = {}
[[token_filters]]
stopwords = "nltk_english"
[[token_filters]]
stemmer = "english_porter2"
$$);

-- 2. Train a model on your own corpus and set up automatic embedding
SELECT create_custom_model_tokenizer_and_trigger(
    tokenizer_name     => 'tech_tok',
    model_name         => 'tech_model',
    text_analyzer_name => 'tech_analyzer',
    table_name         => 'tickets',
    source_column      => 'issue_text',
    target_column      => 'embedding');

-- 3. Insert support tickets; embeddings are generated via trigger
INSERT INTO tickets(issue_text)
VALUES ('Kubernetes pod fails with ExitCode 137 after OOM kill.'),
       ('Network latency spikes to 250ms during peak hours.');

-- 4. Build an index and query as before
CREATE INDEX tickets_emb_bm25 ON tickets USING bm25 (embedding bm25_ops);

SELECT issue_text,
       embedding <&> to_bm25query('tickets_emb_bm25',
                                  tokenize('OOM kill ExitCode 137', 'tech_tok')) AS score
FROM   tickets
ORDER  BY score
LIMIT  5;
```

With a tailor-made vocabulary, the database recognizes abbreviations such as "OOM" and "Kubernetes," yielding more precise rankings for technical support scenarios.

## Final Thoughts

VectorChord-BM25 brings search-engine-quality relevance to the PostgreSQL ecosystem without introducing an additional service layer. By combining flexible tokenization, an efficient BM25 index, and familiar SQL, it enables developers to deliver significantly better search experiences while preserving the operational simplicity of a single database system. If your application relies on PostgreSQL and demands accurate text ranking, VectorChord-BM25 is well worth exploring.
