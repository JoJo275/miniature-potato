-- =========================================================
-- SMART RESEARCH NOTES DATABASE - ENHANCED VERSION
-- Advanced SQLite Demo with FTS5, JSON, Triggers, and AI Search
-- =========================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -64000;  -- 64MB cache
PRAGMA temp_store = MEMORY;

-- =========================================================
-- 1. Core Notes Table with Enhanced Constraints
-- =========================================================
CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL CHECK(length(title) > 0),
    content TEXT NOT NULL CHECK(length(content) > 0),
    metadata JSON DEFAULT '{}' CHECK(json_valid(metadata)),
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    is_archived BOOLEAN DEFAULT 0,
    view_count INTEGER DEFAULT 0,
    last_accessed TEXT
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_notes_archived ON notes(is_archived) WHERE is_archived = 0;

-- Auto-update timestamp
CREATE TRIGGER update_timestamp
AFTER UPDATE ON notes
BEGIN
    UPDATE notes SET updated_at = CURRENT_TIMESTAMP
    WHERE id = new.id;
END;

-- =========================================================
-- 2. Full-Text Search (FTS5)
CREATE VIRTUAL TABLE notes_fts USING fts5(
    title,
    content,
    content='notes',
    content_rowid='id'
);

-- Keep FTS in sync
CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, content)
    VALUES (NEW.id, NEW.title, NEW.content);
END;
CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
    DELETE FROM notes_fts WHERE rowid = OLD.id;
END;
CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN
    UPDATE notes_fts SET title = NEW.title, content = NEW.content
    WHERE rowid = NEW.id;
END;

-- =========================================================
-- 3. Enhanced JSON + Generated Columns
-- =========================================================
ALTER TABLE notes
ADD COLUMN tag_list TEXT GENERATED ALWAYS AS (json_extract(metadata, '$.tags')) STORED;

ALTER TABLE notes
ADD COLUMN author TEXT GENERATED ALWAYS AS (json_extract(metadata, '$.author')) STORED;

ALTER TABLE notes
ADD COLUMN priority INTEGER GENERATED ALWAYS AS (
    COALESCE(json_extract(metadata, '$.priority'), 0)
) STORED;

-- Index for tag searching
CREATE INDEX IF NOT EXISTS idx_notes_tags ON notes(tag_list);
CREATE INDEX IF NOT EXISTS idx_notes_author ON notes(author);
CREATE INDEX IF NOT EXISTS idx_notes_priority ON notes(priority DESC);

-- =========================================================
-- 4. Note Categories Table
-- =========================================================
CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    color TEXT DEFAULT '#808080',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS note_categories (
    note_id INTEGER REFERENCES notes(id) ON DELETE CASCADE,
    category_id INTEGER REFERENCES categories(id) ON DELETE CASCADE,
    PRIMARY KEY (note_id, category_id)
);

-- =========================================================
-- 5. Search History for Analytics
-- =========================================================
CREATE TABLE IF NOT EXISTS search_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    query TEXT NOT NULL,
    result_count INTEGER DEFAULT 0,
    search_type TEXT NOT NULL CHECK(search_type IN ('semantic', 'fts', 'tag')),
    searched_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_search_history_query ON search_history(query);
CREATE INDEX IF NOT EXISTS idx_search_history_date ON search_history(searched_at DESC);

-- =========================================================
-- 6. Note Relationships
-- =========================================================
CREATE TABLE IF NOT EXISTS note_links (
    source_id INTEGER REFERENCES notes(id) ON DELETE CASCADE,
    target_id INTEGER REFERENCES notes(id) ON DELETE CASCADE,
    link_type TEXT DEFAULT 'related',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (source_id, target_id),
    CHECK(source_id != target_id)
);

-- =========================================================
-- 7. Views for Common Queries
-- =========================================================
CREATE VIEW IF NOT EXISTS recent_notes AS
SELECT 
    id, title, 
    substr(content, 1, 200) as preview,
    json_extract(metadata, '$.tags') as tags,
    created_at
FROM notes
WHERE is_archived = 0
ORDER BY created_at DESC
LIMIT 20;

CREATE VIEW IF NOT EXISTS popular_tags AS
SELECT 
    json_each.value as tag,
    COUNT(*) as usage_count
FROM notes, json_each(json_extract(metadata, '$.tags'))
GROUP BY tag
ORDER BY usage_count DESC;

CREATE VIEW IF NOT EXISTS note_statistics AS
SELECT 
    COUNT(*) as total_notes,
    COUNT(DISTINCT author) as total_authors,
    AVG(length(content)) as avg_content_length,
    MAX(view_count) as max_views,
    COUNT(CASE WHEN is_archived = 1 THEN 1 END) as archived_count
FROM notes;

-- =========================================================
-- 8. Enhanced Sample Data
-- =========================================================
INSERT OR IGNORE INTO categories (name, description, color) VALUES
('Physics', 'Physics and quantum mechanics', '#4A90E2'),
('AI/ML', 'Artificial Intelligence and Machine Learning', '#7ED321'),
('Biology', 'Biological sciences', '#50E3C2');

INSERT OR IGNORE INTO notes (title, content, metadata) VALUES
('Quantum Entanglement Basics',
'Entanglement is a fundamental property of quantum mechanics where particles share states. When two particles are entangled, measuring one instantly affects the other regardless of distance.',
'{"tags":["physics","quantum","entanglement"],"author":"Alice","priority":5}'),

('Neural Networks Overview',
'Neural networks are computational models inspired by the human brain. They consist of layers of interconnected nodes that process information through weighted connections.',
'{"tags":["ai","machine learning","neural networks"],"author":"Bob","priority":4}'),

('Photosynthesis and Light',
'Photosynthesis converts light energy into chemical energy in plants. This process involves chlorophyll absorbing light and converting CO2 and water into glucose.',
'{"tags":["biology","plants","photosynthesis"],"author":"Carol","priority":3}'),

('Quantum Computing Principles',
'Quantum computers leverage superposition and entanglement to perform calculations exponentially faster than classical computers for certain problems.',
'{"tags":["physics","quantum","computing"],"author":"Alice","priority":5}'),

('Deep Learning Applications',
'Deep learning has revolutionized computer vision, natural language processing, and many other fields through its ability to learn hierarchical representations.',
'{"tags":["ai","deep learning","applications"],"author":"Bob","priority":4}');

-- Link related notes
INSERT OR IGNORE INTO note_links (source_id, target_id, link_type)
SELECT n1.id, n2.id, 'related'
FROM notes n1, notes n2
WHERE n1.id < n2.id
  AND EXISTS (
    SELECT 1 FROM json_each(json_extract(n1.metadata, '$.tags')) t1,
                   json_each(json_extract(n2.metadata, '$.tags')) t2
    WHERE t1.value = t2.value
  );
