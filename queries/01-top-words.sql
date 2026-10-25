-- 01 Example: top words
-- EXAMPLE: replace with the queries from your guide, one file per SQL block.
SELECT word, total_occurrences, works_appearing_in
FROM `serving.example_top_words`
ORDER BY total_occurrences DESC
LIMIT 10;
