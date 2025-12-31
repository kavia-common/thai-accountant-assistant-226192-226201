#!/bin/bash

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting MySQL setup..."

# Check if MySQL is already running on the specified port
if sudo mysqladmin ping --socket=/var/run/mysqld/mysqld.sock --silent 2>/dev/null; then
    echo "MySQL is already running!"
    
    # Try to verify the database exists
    if sudo mysql --socket=/var/run/mysqld/mysqld.sock -e "USE ${DB_NAME};" 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
    fi
    
    echo ""
    echo "Database: ${DB_NAME}"
    echo "Root user: root (password: ${DB_PASSWORD})"
    echo "App user: appuser (password: ${DB_PASSWORD})"
    echo "Port: ${DB_PORT}"
    echo ""
    
    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "To connect to the database, use:"
        echo "$(cat db_connection.txt)"
    else
        echo "To connect to the database, use:"
        echo "mysql -u root -p${DB_PASSWORD} -h localhost -P ${DB_PORT} ${DB_NAME}"
    fi
    
    echo ""
    echo "Script stopped - MySQL server already running."
    exit 0
fi

# Check if there's a MySQL process running on the specified port
if pgrep -f "mysqld.*--port=${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing MySQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."
    
    # Try to connect via TCP
    if mysql -u root -p${DB_PASSWORD} -h 127.0.0.1 -P ${DB_PORT} -e "SELECT 1;" 2>/dev/null; then
        echo "MySQL is accessible on port ${DB_PORT}."
        echo "Script stopped - server already running."
        exit 0
    fi
fi

# Check if MySQL is running on default socket but different port
if [ -S /var/run/mysqld/mysqld.sock ]; then
    echo "Found MySQL socket, checking if it's using port ${DB_PORT}..."
    CURRENT_PORT=$(sudo mysql --socket=/var/run/mysqld/mysqld.sock -e "SHOW VARIABLES LIKE 'port';" 2>/dev/null | grep port | awk '{print $2}')
    if [ "$CURRENT_PORT" = "${DB_PORT}" ]; then
        echo "MySQL is already running on port ${DB_PORT}!"
        echo "Script stopped - server already running."
        exit 0
    else
        echo "MySQL is running on different port ($CURRENT_PORT), stopping it first..."
        sudo mysqladmin shutdown --socket=/var/run/mysqld/mysqld.sock
        sleep 5
    fi
fi

# Initialize MySQL data directory if it doesn't exist
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MySQL..."
    sudo mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql
fi

# Start MySQL server in background using sudo
echo "Starting MySQL server..."
sudo mysqld --user=mysql --datadir=/var/lib/mysql --socket=/var/run/mysqld/mysqld.sock --pid-file=/var/run/mysqld/mysqld.pid --port=${DB_PORT} &

# Wait for MySQL to be ready
echo "Waiting for MySQL to start..."
sleep 5

# Check if MySQL is running using socket
for i in {1..15}; do
    if sudo mysqladmin ping --socket=/var/run/mysqld/mysqld.sock --silent 2>/dev/null; then
        echo "MySQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Configure database and user - Fix MySQL 8.0 authentication
echo "Setting up database and fixing authentication..."
sudo mysql --socket=/var/run/mysqld/mysqld.sock << EOF
-- Fix root user authentication for MySQL 8.0
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';

-- Create database
CREATE DATABASE IF NOT EXISTS ${DB_NAME};

-- Create a new user for remote connections
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'appuser'@'%';

-- Grant privileges to root
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'root'@'localhost';

FLUSH PRIVILEGES;
EOF

# Save connection command to a file
echo "mysql -u ${DB_USER} -p${DB_PASSWORD} -h localhost -P ${DB_PORT} ${DB_NAME}" > db_connection.txt
echo "Connection command saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/mysql.env << EOF
export MYSQL_URL="mysql://localhost:${DB_PORT}/${DB_NAME}"
export MYSQL_USER="${DB_USER}"
export MYSQL_PASSWORD="${DB_PASSWORD}"
export MYSQL_DB="${DB_NAME}"
export MYSQL_PORT="${DB_PORT}"
EOF

echo "MySQL setup complete!"
echo "Database: ${DB_NAME}"
echo "Root user: root (password: ${DB_PASSWORD})"
echo "App user: appuser (password: ${DB_PASSWORD})"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/mysql.env"
echo "To use with Node.js viewer, run: source db_visualizer/mysql.env"

echo "To connect to the database, use the following command:"
echo "$(cat db_connection.txt)"

echo ""
echo "MySQL is running in the background."
echo "You can now start your application."
