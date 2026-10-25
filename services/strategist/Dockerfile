FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

# One worker and one thread: moments are answered one at a time, so a moment
# delivered twice cannot be answered twice in parallel.
CMD exec gunicorn --bind :$PORT --workers 1 --threads 1 --timeout 90 main:app
