FROM python:3.13-slim AS base
WORKDIR /app
COPY pyproject.toml ./
RUN pip install --no-cache-dir fastapi==0.136.1 'uvicorn[standard]==0.46.0'

FROM base
COPY src ./src
RUN useradd -u 10001 -m app && chown -R app:app /app
USER 10001
ENV PYTHONPATH=/app/src
EXPOSE 8080
CMD ["uvicorn", "hello.main:app", "--host", "0.0.0.0", "--port", "8080"]