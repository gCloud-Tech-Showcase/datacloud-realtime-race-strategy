FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
COPY static ./static

CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 150 main:app
