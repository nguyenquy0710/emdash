FROM node:22-alpine AS build
RUN npm install -g pnpm
WORKDIR /app
COPY . .
RUN pnpm install --frozen-lockfile
RUN pnpm run build

FROM node:22-alpine AS runtime
RUN npm install -g pnpm
WORKDIR /app
COPY --from=build /app ./
RUN pnpm install --frozen-lockfile

EXPOSE 4321
CMD ["pnpm", "emdash", "dev"]
