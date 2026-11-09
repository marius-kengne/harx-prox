RUN echo "=== NODE ===" \
    && node -v \
    && echo "=== BROTLI RPM ===" \
    && rpm -qa | grep -i brotli \
    && echo "=== LIBRAIRIES NODE ===" \
    && (ldd "$(command -v node)" | grep -i brotli || true)
