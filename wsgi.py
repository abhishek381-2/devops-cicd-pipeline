"""WSGI entrypoint used by Gunicorn.

gunicorn --bind 0.0.0.0:8000 --workers 3 wsgi:app
"""

from app import create_app

app = create_app()

if __name__ == "__main__":
    # Binding 0.0.0.0 is required inside a container: 127.0.0.1 would be
    # unreachable from the Nginx container next to it.
    app.run(host="0.0.0.0", port=app.config.get("APP_PORT", 8000))  # noqa: S104
