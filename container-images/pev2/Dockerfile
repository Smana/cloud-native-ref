FROM nginx:alpine

ARG PEV2_VERSION=v1.17.0

# Remove default nginx config and content
RUN rm -rf /etc/nginx/conf.d/* /usr/share/nginx/html/*

# Download official PEV2 from GitHub releases
RUN wget -O /usr/share/nginx/html/index.html \
    https://github.com/dalibo/pev2/releases/download/${PEV2_VERSION}/pev2.html

# Copy custom nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Create cache and temp directories with proper permissions
# nginx.pid will be written to /tmp (mounted as emptyDir in Kubernetes)
RUN mkdir -p /var/cache/nginx/client_temp \
    /var/cache/nginx/proxy_temp \
    /var/cache/nginx/fastcgi_temp \
    /var/cache/nginx/uwsgi_temp \
    /var/cache/nginx/scgi_temp \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /usr/share/nginx/html \
    && chmod -R 755 /var/cache/nginx

# Run as non-root user
USER nginx

# Expose port 8080 (non-privileged port)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
