FROM python:3.11-slim

LABEL maintainer="scRNA-Studio"
LABEL description="scRNA-seq Pipeline Web Interface (Portable)"

# Install system dependencies required for remote execution and SSH tunneling
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    rsync \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy python requirements first to leverage Docker layer caching
COPY webapp/requirements.txt ./webapp/requirements.txt
RUN pip install --no-cache-dir -r webapp/requirements.txt

# Copy the entire pipeline structure (webapp and nextflow logic)
COPY webapp/ ./webapp/
COPY nextflow/ ./nextflow/

# Expose the Flask default port
EXPOSE 5000

ENV FLASK_ENV=production

# The working directory for execution should be inside webapp
WORKDIR /app/webapp

# Run the application
CMD ["python", "app.py", "5000"]
