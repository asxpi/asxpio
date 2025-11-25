FROM nginx:alpine

# Copy website files to nginx html directory
COPY index.html /usr/share/nginx/html/
COPY id_ed25519.pub /usr/share/nginx/html/
COPY copyPGP.js /usr/share/nginx/html/
COPY copySSH.js /usr/share/nginx/html/
COPY hedgehog.png /usr/share/nginx/html/
COPY pgp.pub /usr/share/nginx/html/

# Expose port 80
EXPOSE 80

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
