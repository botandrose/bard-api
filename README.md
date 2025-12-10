# Bard::Api

REST API for BARD-managed Rails projects. This gem provides a lightweight Rack application that mounts in Rails projects to expose management endpoints for BARD Tracker.

## Overview

The bard-api gem enables BARD Tracker to manage Rails applications through a REST API. It provides:

- **Database backups**: Trigger and monitor database backups using Backhoe
- **Health monitoring**: Check application status

## Usage

### Mounting in Rails

Add to your `config/routes.rb`:

```ruby
mount Bard::Api::App.new => "/bard-api"
```

This makes the API available at `/bard-api/*` endpoints.

### Endpoints

#### GET /bard-api/health

Health check endpoint (no authentication required).

**Response:**
```json
{
  "status": "ok"
}
```

#### POST /bard-api/backups

Trigger a backup (requires JWT authentication).

**Headers:**
```
Authorization: Bearer <jwt-token>
```

**Request:**
```json
{
  "urls": [
    "https://s3.amazonaws.com/presigned-url..."
  ]
}
```

**Response (200 OK):**
```json
{
  "timestamp": "2025-12-06T10:30:00Z",
  "size": 123456789,
  "destinations": [
    {
      "name": "bard",
      "type": "bard",
      "status": "success"
    }
  ]
}
```

#### GET /bard-api/backups/latest

Get status of most recent backup (requires JWT authentication).

**Headers:**
```
Authorization: Bearer <jwt-token>
```

**Response (200 OK):**
```json
{
  "timestamp": "2025-12-06T10:30:00Z",
  "destinations": [
    {
      "name": "primary",
      "type": "s3",
      "path": "bard-backup/my-app",
      "region": "us-west-2"
    }
  ]
}
```

**Response (404 Not Found):**
```json
{
  "error": "No backups found"
}
```

### Authentication

The API uses JWT with asymmetric RSA keys for authentication. The public key is embedded in the gem, and only BARD Tracker with the private key can create valid tokens.

Tokens expire after 5 minutes and must include:
- `urls`: Array of presigned S3 URLs for backup destinations
- `exp`: Expiration timestamp
- `iat`: Issued at timestamp

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
