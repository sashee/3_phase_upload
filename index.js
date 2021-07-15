const AWS = require("aws-sdk");
const fs = require("fs").promises;
const util = require("util");

const s3 = new AWS.S3({
	signatureVersion: "v4",
});

const dynamodb = new AWS.DynamoDB();

const randomString = () =>	require("crypto").randomBytes(16).toString("hex");

const getSignedInUser = (event) => {
	if (event.headers.Cookie) {
		return event.headers.Cookie.split(";").map((cookie) => cookie.trim().split("=")).find(([name]) => name === "username")[1];
	}else {
		return undefined;
	}
};

module.exports.handler = async (event) => {
	const userAvatarPath = /\/user\/(?<username>[^/]*)\/avatar/;
	if (event.path === "/") {
		const [html, bucketTable, ddbTable] = await Promise.all([
			fs.readFile(__dirname+"/index.html", "utf8"),
			(async () => {
				// does not handle pagination, only for demonstration
				const objects = await s3.listObjectsV2({Bucket: process.env.BUCKET}).promise();
				const contents = await Promise.all(objects.Contents.map(async (object) => {
					const objectMeta = await s3.headObject({Bucket: process.env.BUCKET, Key: object.Key}).promise();

					return {
						key: object.Key,
						size: object.Size,
						metadata: objectMeta.Metadata,
						expiration: objectMeta.Expiration,
						contentType: objectMeta.ContentType,
						lastModified: objectMeta.LastModified.toISOString(),
					};
				}));

				return contents
					.sort((a, b) => a.lastModified < b.lastModified ? -1 : a.lastModified > b.lastModified ? 1 : 0)
					.reverse()
					.map(({key, lastModified, size, metadata, contentType, expiration}) => {
						return `
	<tr>
		<td>${key}</td>
		<td>${lastModified}</td>
		<td>${size}</td>
		<td>${contentType}</td>
		<td>
			<pre>${JSON.stringify(metadata, undefined, 4)}</pre>
		</td>
		<td>${expiration}</td>
	</tr>
						`;
					})
					.join("");

			})(),
			(async () => {
				const items = await dynamodb.scan({
					TableName: process.env.TABLE,
				}).promise();

				return items.Items.map(({Username: {S: Username}, Name: {S: Name}, Avatar: {S: Avatar}}) => `
<tr>
	<td>${Username}</td>
	<td>${Name}</td>
	<td>${Avatar}</td>
</tr>
					`).join("");
			})(),
		]);

		const htmlWithDebug = html.replace("$$BUCKET_CONTENTS$$", bucketTable).replace("$$TABLE_CONTENTS$$", ddbTable);

		return {
			statusCode: 200,
			headers: {
				"Content-Type": "text/html",
			},
			body: htmlWithDebug,
		};
	} else if (event.path === "/users") {
		const items = await dynamodb.scan({
			TableName: process.env.TABLE,
		}).promise();

		const result = items.Items.map(({Username: {S: Username}, Name: {S: Name}}) => ({Username, Name}));

		return {
			statusCode: 200,
			headers: {
				"Content-Type": "text/json",
			},
			body: JSON.stringify(result),
		};
	} else if (event.httpMethod === "PUT" && event.path === "/login" && event.body) {
		const username = JSON.parse(event.body).username;

		return {
			statusCode: 200,
			headers: {
				"Set-Cookie": `username=${username}`,
			},
		};
	} else if (event.path === "/whoami") {
		const username = getSignedInUser(event);

		return {
			statusCode: 200,
			headers: {
				"Content-Type": "text/json",
			},
			body: JSON.stringify({username}),
		};
	} else if (event.path.match(userAvatarPath)) {
		const {username} = event.path.match(userAvatarPath).groups;

		const user = await dynamodb.getItem({
			TableName: process.env.TABLE,
			Key: {
				Username: {
					S: username,
				},
			},
		}).promise();

		const avatarKey = user.Item.Avatar.S;

		const avatarImage = await s3.getSignedUrlPromise("getObject", {Bucket: process.env.BUCKET, Key: avatarKey});

		return {
			statusCode: 303,
			headers: {
				Location: avatarImage,
			},
		};
	} else if (event.path === "/get_upload_url") {
		const username = getSignedInUser(event);
		const key = randomString();

		const data = await util.promisify(s3.createPresignedPost.bind(s3))({
			Bucket: process.env.BUCKET,
			Fields: {
				key: `pending/${key}`,
			},
			Conditions: [
				["content-length-range", 	0, 1000000], // content length restrictions: 0-1MB
				["starts-with", "$Content-Type", "image/"], // content type restriction
				["eq", "$x-amz-meta-username", username],
			]
		});

		// add the required fields
		data.fields["x-amz-meta-username"] = username;

		data.key = key;

		return {
			statusCode: 200,
			headers: {
				"Content-Type": "text/json",
			},
			body: JSON.stringify(data),
		};
	} else if (event.path === "/update_avatar" && event.httpMethod === "POST" && event.body) {
		const {key} = JSON.parse(event.body);

		const username = getSignedInUser(event);

		// move object out of the pending directory
		const moveObject = async () => {
			await s3.copyObject({
				Bucket: process.env.BUCKET,
				Key: key,
				CopySource: encodeURI(`${process.env.BUCKET}/pending/${key}`),
			}).promise();
			await s3.deleteObject({Bucket: process.env.BUCKET, Key: `pending/${key}`}).promise();
		};

		const getCurrentAvatar = async () => {
			return (await dynamodb.getItem({TableName: process.env.TABLE, Key: {Username: {S: username}}}).promise()).Item.Avatar.S;
		};

		const [, oldAvatar] = await Promise.all([moveObject(), getCurrentAvatar()]);

		// set the avatar

		await dynamodb.updateItem({
			TableName: process.env.TABLE,
			Key: {
				Username: {
					S: username,
				},
			},
			ConditionExpression: "Avatar = :oldAvatar",
			ExpressionAttributeValues: {
				":oldAvatar": {S: oldAvatar},
				":newAvatar": {S: key},
			},
			UpdateExpression: "SET Avatar = :newAvatar"
		}).promise();
		await s3.deleteObject({Bucket: process.env.BUCKET, Key: oldAvatar}).promise();
		return {
			statusCode: 200,
		};
	}
};
