# NGINX Docker Image

This repository contains a Dockerfile to build a NGINX image with additional modules and features. The resulting image is based on Alpine Linux.

## Features

* Alpine Linux version: latest
* NGINX version: 1.29.5
* Additional modules:
  - ngx_cache_purge (version 2.3)
  - headers-more-nginx-module (version 0.34)
  - ngx_brotli (version 1.0.0rc)
  - http_v3_module （with boringssl）
* SSL/TLS support
* Exposed ports: 80 (HTTP) and 443 (HTTPS)
* Configurable volumes for website content, Let's Encrypt certificates, and NGINX logs

## Build and Run

To build the Docker image, use the following command:

```sh
docker build -t nginx -f mainline/alpine/Dockerfile .
```

---

To run the container based on the built image, use the following command:

```sh
docker run -d -p 80:80/tcp -p 80:80/udp -p 443:443/tcp -p 443:443/udp -v /path/to/website:/var/www/html -v /path/to/certificates:/etc/letsencrypt -v /path/to/logs:/var/log/nginx nginx
```

Make sure to replace /path/to/website, /path/to/certificates, and /path/to/logs with the actual paths on your host machine.

## Configuration

The NGINX configuration files and templates can be found in `mainline/alpine/files`.

* nginx.conf: Main NGINX configuration file.
* fastcgi_params: FastCGI configuration parameters.
* templates/: Directory containing additional NGINX configuration templates.
* At build time, the image creates default self-signed certificate/key pairs under `/etc/letsencrypt`.
* In production, mount real certificates into `/etc/letsencrypt` to override the defaults.
* TLS defaults are hardened in `ssl.inc` (TLSv1.2/1.3, modern ciphers, session tickets disabled).

## Notes
* The NGINX image is set to automatically reload every 30 days to apply configuration changes, including updates to SSL certificates. This ensures that any modifications made to the SSL certificates, such as renewals or updates, will be incorporated into the NGINX server without requiring manual intervention. The reloading interval can be customized according to your specific requirements.
* The NGINX logs are stored in the /var/log/nginx directory inside the container. Mount a volume at this location to persist the logs on the host machine.

## Contributing
If you have any suggestions, improvements, or issues, feel free to create an issue or pull request in the GitHub repository.

## License
This project is licensed under the GPLv3 License.
