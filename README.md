# NGINX Docker Image

This repository contains a Dockerfile to build a NGINX image with additional modules and features. The resulting image is based on Alpine Linux.

## Features

* Alpine Linux version: latest
* NGINX version: 1.27.0
* Additional modules:
  - ngx_cache_purge (version 2.3)
  - headers-more-nginx-module (version 0.34)
  - http_v3_module （with boringssl）
* SSL/TLS support with Let's Encrypt certificates
* Healthcheck endpoint at /healthcheck
* Exposed ports: 80 (HTTP) and 443 (HTTPS)
* Configurable volumes for website content, Let's Encrypt certificates, and NGINX logs

## Build and Run

To build the Docker image, use the following command:

```sh
docker build -t nginx .
```

---

To run the container based on the built image, use the following command:

```sh
docker run -d -p 80:80/tcp -p 80:80/udp -p 443:443/tcp -p 443:443/udp -v /path/to/website:/var/www/html -v /path/to/certificates:/etc/letsencrypt -v /path/to/logs:/var/log/nginx nginx
```

Make sure to replace /path/to/website, /path/to/certificates, and /path/to/logs with the actual paths on your host machine.

## Configuration

The NGINX configuration files and templates can be found in the files directory. Modify these files according to your requirements before building the Docker image.

* nginx.conf: Main NGINX configuration file.
* fastcgi_params: FastCGI configuration parameters.
* templates/: Directory containing additional NGINX configuration templates.
* ssl/: Directory containing SSL/TLS certificates, ssl_dhparam file and ssl_session_ticket_key file. Place your Let's Encrypt certificates, ssl_dhparam file and ssl_session_ticket_key file in this directory.
  - ssl_dhparam file: This is the file used for Diffie-Hellman parameters. You can generate this file using OpenSSL tool to enhance the security of SSL/TLS connections. To generate the DH parameters, you can use the `openssl` command-line tool. Here's an example command to generate a 2048-bit DH parameter file:
    ```sh
    openssl dhparam -out /etc/letsencrypt/dhparam.pem 2048
    ```
  - ssl_session_ticket_key file: This is the file used for session ticket keys. Session tickets are a mechanism used to optimize the SSL/TLS handshake process. You can generate this key file using the OpenSSL tool. Here's an example command:
    ```sh
    openssl rand 80 > /etc/letsencrypt/session_ticket.key
    ```

    **Please note that generating DH parameter files and session ticket key files involve key material, so it's important to handle and protect these files properly. It is recommended to restrict the permissions of the files and store them in a secure location.**

## Notes
* The NGINX image is set to automatically reload every 30 days to apply configuration changes, including updates to SSL certificates. This ensures that any modifications made to the SSL certificates, such as renewals or updates, will be incorporated into the NGINX server without requiring manual intervention. The reloading interval can be customized according to your specific requirements.
* The NGINX logs are stored in the /var/log/nginx directory inside the container. Mount a volume at this location to persist the logs on the host machine.
* You can utilize the nginx-module-vts module by accessing "/vhost_traffic_status_display". You can modify this configuration in the "ssl.conf" file.

## Contributing
If you have any suggestions, improvements, or issues, feel free to create an issue or pull request in the GitHub repository.

## License
This project is licensed under the GPLv3 License.
