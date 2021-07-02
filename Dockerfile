FROM python:3.9.6-slim

COPY . /src

RUN pip install -r /src/requirements.txt

ENTRYPOINT hy /src/main.hy
