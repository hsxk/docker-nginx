# SSL
ssl_dhparam /etc/letsencrypt/dhparam.pem;

ssl_session_tickets off;

ssl_session_cache shared:SSL:20m;
ssl_session_timeout 10m;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
ssl_ecdh_curve X25519:secp384r1:prime256v1;
ssl_prefer_server_ciphers off;
