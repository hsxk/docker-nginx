fastcgi_split_path_info ^(.+?\.php)(/.*)$;
if (!-f $document_root$fastcgi_script_name) {
    return 404;
}
fastcgi_pass php-fpm:9000;
fastcgi_index index.php;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
include fastcgi_params;
fastcgi_buffers 256 128k;
fastcgi_buffer_size 128k;
fastcgi_intercept_errors on;
fastcgi_read_timeout 120s;
