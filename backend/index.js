const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");

const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);
//const DB_PASSWORD = "super-secret-password-123"; // Vulnerabilidad: Hardcoded Secret

exports.handler = async (event) => {
    console.log("Evento recibido:", event.body);
    
    try {
        // Lambda Function URLs a veces recibe el body en base64, pero simplificaremos asumiendo JSON puro
        const body = JSON.parse(event.body);
        
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
            body: JSON.stringify({ message: "¡Datos guardados con éxito en DynamoDB!" })
        };
    } catch (error) {
        console.error("Error guardando datos:", error);
        return {
            statusCode: 500,
            body: JSON.stringify({ message: "Error interno del servidor" })
        };
    }
};
