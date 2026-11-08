FROM python:3.12-alpine
RUN apk add --no-cache ffmpeg
RUN pip install --no-cache-dir yt-dlp
ENTRYPOINT ["yt-dlp"]
