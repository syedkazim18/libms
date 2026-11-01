# Database connection settings. EDIT DB_PASSWORD to your MySQL root password.
import os
DB = dict(
    host=os.getenv("DB_HOST", "127.0.0.1"),
    port=int(os.getenv("DB_PORT", "3306")),
    user=os.getenv("DB_USER", "root"),
    password=os.getenv("DB_PASSWORD", ""),
    database="library_db",
)
SECRET_KEY = os.getenv("SECRET_KEY", "change-this-secret-before-submitting")
PAGE_SIZE = 12
