const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");

const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);

exports.handler = async (event) => {
    // Definición estricta de headers para CORS
    const method = event.requestContext?.http?.method || event.httpMethod;
    const headers = {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Expose-Headers": "Content-Type",
        "Vary": "Origin"
    };

    if (method === 'OPTIONS') {
        return { statusCode: 200, headers };
    }

    try {
        const body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
        
        const item = {
            id: Date.now().toString(),
            nombre: body.nombre,
            email: body.email,
            mensaje: body.mensaje,
            fecha: new Date().toISOString()
        };

        const command = new PutCommand({
            TableName: process.env.TABLE_NAME,
            Item: item
        });

        await docClient.send(command);

        return {
            statusCode: 200,
            headers: { ...headers, "Content-Type": "application/json; charset=utf-8" },
            body: JSON.stringify({ message: "¡Datos guardados con éxito en DynamoDB!" })
        };
    } catch (error) {
        console.error("Error:", error);
        return {
            statusCode: 500,
            headers: { ...headers, "Content-Type": "application/json; charset=utf-8" },
            body: JSON.stringify({ message: "Error interno del servidor" })
        };
    }
};