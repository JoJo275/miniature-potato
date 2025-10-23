import sqlite3
import numpy as np
from openai import OpenAI
import logging
import os
from typing import List, Tuple, Optional
from functools import lru_cache
from contextlib import contextmanager
import time
from dataclasses import dataclass
from dotenv import load_dotenv

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load environment variables
load_dotenv()

@dataclass
class SearchResult:
    """Data class for search results"""
    title: str
    content: str
    distance: float
    note_id: int

class SmartNotesDB:
    """Enhanced smart notes database with vector search capabilities"""
    
    def __init__(self, db_path: str = "smart_notes.db", openai_api_key: Optional[str] = None):
        self.db_path = db_path
        self.client = OpenAI(api_key=openai_api_key or os.getenv("OPENAI_API_KEY"))
        self.embedding_model = "text-embedding-3-small"
        self._init_database()
    
    @contextmanager
    def get_connection(self):
        """Context manager for database connections"""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()
    
    def _init_database(self):
        """Initialize database with proper error handling"""
        with self.get_connection() as conn:
            cur = conn.cursor()
            
            # Try to load sqlite-vss extension
            try:
                conn.enable_load_extension(True)
                conn.load_extension("sqlite-vss")
                logger.info("sqlite-vss extension loaded successfully")
            except (AttributeError, sqlite3.OperationalError) as e:
                logger.warning(f"Could not load sqlite-vss: {e}")
            
            # Create vector table if extension is available
            try:
                cur.execute(f"""
                cur.execute(f"""
                CREATE VIRTUAL TABLE IF NOT EXISTS note_embeddings USING vss0(
                    id INTEGER PRIMARY KEY,
                    embedding({self.embedding_dimension})
                )
                """)
                conn.commit()
                logger.info("Vector search table created")
                logger.error(f"Could not create vector table: {e}")
    
    @staticmethod
    def _get_embedding_cached(client, model: str, text: str) -> np.ndarray:
        """Get embedding for a given text"""
        try:
            response = client.embeddings.create(
                model=model,
                input=text
            )
            return np.array(response.data[0].embedding, dtype=np.float32)
        except Exception as e:
            logger.error(f"Error generating embedding: {e}")
            raise
    
    def add_embeddings_batch(self, notes: List[Tuple[int, str]], batch_size: int = 10):
        """Add embeddings in batches for better performance"""
        with self.get_connection() as conn:
            cur = conn.cursor()
            
            for i in range(0, len(notes), batch_size):
                batch = notes[i:i + batch_size]
                texts = [text for _, text in batch]
                
                try:
                    # Generate embeddings in batch
                    response = self.client.embeddings.create(
                        model=self.embedding_model,
                        input=texts
                    )
                    
                    # Insert embeddings
                    for (note_id, _), embedding_data in zip(batch, response.data):
                        embedding = np.array(embedding_data.embedding, dtype=np.float32)
                        blob = embedding.tobytes()
                        cur.execute(
                            "INSERT OR REPLACE INTO note_embeddings (id, embedding) VALUES (?, ?)",
                            (note_id, blob)
                        )
                    
                    conn.commit()
                    logger.info(f"Processed batch {i//batch_size + 1}/{(len(notes)-1)//batch_size + 1}")
                    
                except Exception as e:
                    logger.error(f"Error processing batch: {e}")
                    conn.rollback()
                
                # Rate limiting
                time.sleep(0.1)
    
    def semantic_search(self, query: str, limit: int = 5) -> List[SearchResult]:
        """Perform semantic search with error handling"""
        try:
            # Get query embedding
            embedding = SmartNotesDB._get_embedding_cached(self.client, self.embedding_model, query)
            blob = embedding.tobytes()
            
            with self.get_connection() as conn:
                cur = conn.cursor()
                
                # Perform vector search
                results = cur.execute("""
                SELECT n.id, n.title, n.content, v.distance
                FROM note_embeddings
                JOIN vss_search(note_embeddings, ?, ?) v ON note_embeddings.id = v.id
                JOIN notes n ON n.id = note_embeddings.id
                ORDER BY v.distance ASC
                """, (blob, limit)).fetchall()
                
                return [
                    SearchResult(
                        note_id=r[0],
                        title=r[1],
                        content=r[2],
                        distance=r[3]
                    ) for r in results
                ]
        
        except sqlite3.OperationalError as e:
            logger.error(f"Database error during search: {e}")
            # Fallback to FTS5 search
            return self.fallback_text_search(query, limit)
    
    def fallback_text_search(self, query: str, limit: int = 5) -> List[SearchResult]:
        """Fallback to FTS5 if vector search fails"""
        with self.get_connection() as conn:
            cur = conn.cursor()
            results = cur.execute("""
            SELECT n.id, n.title, n.content, 
                   rank * -1 as distance
            FROM notes_fts f
            JOIN notes n ON f.rowid = n.id
            WHERE notes_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """, (query, limit)).fetchall()
            
            return [
                SearchResult(
                    note_id=r[0],
                    title=r[1],
                    content=r[2],
                    distance=r[3]
                ) for r in results
            ]
    
    def update_all_embeddings(self):
        """Update embeddings for all notes"""
        with self.get_connection() as conn:
            cur = conn.cursor()
            rows = cur.execute(
                "SELECT id, title || ' ' || content FROM notes"
            ).fetchall()
            
            notes_data = [(row[0], row[1]) for row in rows]
            logger.info(f"Updating embeddings for {len(notes_data)} notes")
            self.add_embeddings_batch(notes_data)

def main():
    """Main execution with improved error handling"""
    try:
        # Initialize database
        db = SmartNotesDB()
        
        # Update all embeddings
        db.update_all_embeddings()
        
        # Perform search
        query = "quantum mechanics entanglement"
        logger.info(f"Searching for: '{query}'")
        
        results = db.semantic_search(query, limit=3)
        
        print("\n" + "="*60)
        print(f"Search Results for: '{query}'")
        print("="*60)
        
        for i, result in enumerate(results, 1):
            print(f"\n{i}. {result.title}")
            print(f"   Score: {result.distance:.4f}")
            print(f"   Preview: {result.content[:150]}...")
            print("-"*60)
    
    except Exception as e:
        logger.error(f"Application error: {e}")
        raise

if __name__ == "__main__":
    main()
