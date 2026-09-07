FROM python:3.12-alpine

RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY app.py .

USER app

EXPOSE 8080

CMD ["python", "app.py"]
