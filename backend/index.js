const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");

const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);

// CORRECCIÓN: En Lambda usamos process.env, no import.meta.env
// import.meta es para navegadores/Vite.
const API_URL = process.env.API_ENDPOINT || "http://localhost";

exports.handler = async (event) => {
    console.log("Evento recibido:", event.body);
    
    try {
        // En Lambda, a veces el body viene como string, hay que parsearlo
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
            headers: {
                "Access-Control-Allow-Origin": "*", // Necesario para evitar bloqueos CORS
                "Content-Type": "application/json"
            },
            body: JSON.stringify({ message: "¡Datos guardados con éxito en DynamoDB!" })
        };
    } catch (error) {
        console.error("Error guardando datos:", error);
        return {
            statusCode: 500,
            headers: {
                "Access-Control-Allow-Origin": "*",
                "Content-Type": "application/json"
            },
            body: JSON.stringify({ message: "Error interno del servidor" })
        };
    }
};