package com.academic.config;

import java.io.IOException;
import java.io.InputStream;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Properties;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Academic Result Input Validator - Database Connection Manager
 * Manages JDBC connections, properties configuration, and transaction lifecycle.
 */
public class DBConnection {

    private static final Logger LOGGER = Logger.getLogger(DBConnection.class.getName());
    private static final Properties properties = new Properties();
    private static boolean driverLoaded = false;

    static {
        loadConfiguration();
    }

    private static synchronized void loadConfiguration() {
        try (InputStream input = DBConnection.class.getClassLoader().getResourceAsStream("db.properties")) {
            if (input == null) {
                LOGGER.log(Level.WARNING, "db.properties not found on classpath. Using default localhost settings.");
                properties.setProperty("db.driver", "com.mysql.cj.jdbc.Driver");
                properties.setProperty("db.url", "jdbc:mysql://localhost:3306/academic_result_db?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC&characterEncoding=utf8mb4");
                properties.setProperty("db.user", "root");
                properties.setProperty("db.password", "");
            } else {
                properties.load(input);
            }

            String driver = properties.getProperty("db.driver", "com.mysql.cj.jdbc.Driver");
            Class.forName(driver);
            driverLoaded = true;
            LOGGER.log(Level.INFO, "MySQL JDBC Driver successfully loaded: {0}", driver);

        } catch (ClassNotFoundException e) {
            LOGGER.log(Level.SEVERE, "MySQL JDBC Driver class not found in classpath: " + e.getMessage(), e);
        } catch (IOException e) {
            LOGGER.log(Level.SEVERE, "Failed to load db.properties: " + e.getMessage(), e);
        }
    }

    /**
     * Obtains a new connection to the MySQL database.
     * @return active java.sql.Connection
     * @throws SQLException if a database access error occurs
     */
    public static Connection getConnection() throws SQLException {
        if (!driverLoaded) {
            loadConfiguration();
        }
        String url = properties.getProperty("db.url");
        String user = properties.getProperty("db.user");
        String password = properties.getProperty("db.password");

        return DriverManager.getConnection(url, user, password);
    }

    /**
     * Safe connection check method to verify database availability.
     * @return true if connection can be established and validated, false otherwise.
     */
    public static boolean testConnection() {
        try (Connection conn = getConnection()) {
            return conn != null && !conn.isClosed() && conn.isValid(3);
        } catch (SQLException e) {
            LOGGER.log(Level.WARNING, "Database connection test failed: {0}", e.getMessage());
            return false;
        }
    }

    /**
     * Gracefully close a database Connection.
     */
    public static void close(Connection conn) {
        if (conn != null) {
            try {
                conn.close();
            } catch (SQLException e) {
                LOGGER.log(Level.WARNING, "Error closing connection: {0}", e.getMessage());
            }
        }
    }

    /**
     * Gracefully close a Statement or PreparedStatement.
     */
    public static void close(Statement stmt) {
        if (stmt != null) {
            try {
                stmt.close();
            } catch (SQLException e) {
                LOGGER.log(Level.WARNING, "Error closing statement: {0}", e.getMessage());
            }
        }
    }

    /**
     * Gracefully close a ResultSet.
     */
    public static void close(ResultSet rs) {
        if (rs != null) {
            try {
                rs.close();
            } catch (SQLException e) {
                LOGGER.log(Level.WARNING, "Error closing result set: {0}", e.getMessage());
            }
        }
    }

    /**
     * Safely rolls back a transaction.
     */
    public static void rollback(Connection conn) {
        if (conn != null) {
            try {
                conn.rollback();
            } catch (SQLException e) {
                LOGGER.log(Level.WARNING, "Error rolling back transaction: {0}", e.getMessage());
            }
        }
    }
}
