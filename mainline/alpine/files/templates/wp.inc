# WordPress
index index.php index.html index.htm;

rewrite /wp-admin$ $scheme://$host$uri/ permanent;

location / {
    try_files $uri $uri/ /index.php?$args;
}

location ~* /\. {
    deny all;
}

location ~* /(?:uploads|files)/.*\.php$ {
    deny all;
}

location ~* /wp-login\.php|/wp-admin/((?!(admin-ajax\.php|images/)).)*$ {
    satisfy any;
    allow 0.0.0.0/0;
    allow 127.0.0.1;
    deny all;

    location ~ [^/]\.php(/|$) {
        include /etc/nginx/conf.d/fastcgi.inc;
        include /etc/nginx/naxsi.conf;
    }
    include /etc/nginx/naxsi.conf;
}

location ~ [^/]\.php(/|$) {
    include conf.d/fastcgi.inc;
    if ($request_uri ~* "(/wp-admin/|/xmlrpc.php|/wp-(app|cron|login|register|mail).php|wp-.*.php|/feed/|index.php|wp-comments-popup.php|wp-links-opml.php|wp-locations.php|sitemap(_index)?.xml|[a-z0-9_-]+-sitemap([0-9]+)?.xml)") {
        set $do_not_cache 1;
    }

    include conf.d/fastcgi_cache.inc;
    include /etc/nginx/naxsi.conf;
}
