
FROM node:22-alpine as build

WORKDIR /app

RUN npm install -g pnpm

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

RUN pnpm run build

FROM node:22-alpine

WORKDIR /app

RUN npm install -g pnpm

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/pnpm-lock.yaml ./pnpm-lock.yaml

COPY --from=build /app/dist ./dist

COPY . .

EXPOSE 4321

CMD ["pnpm", "emdash", "dev"]
