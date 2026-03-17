FROM node:20 AS builder

WORKDIR /app

ARG NEXT_PUBLIC_API_URL=http://localhost/api
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ pkg-config \
    libx11-dev libxi-dev libxext-dev libglx-dev libgl1-mesa-dev \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

COPY nightingale/ ./nightingale/

RUN cd nightingale && yarn install --frozen-lockfile && yarn build

COPY package.json yarn.lock ./

RUN yarn install --ignore-scripts

COPY . .
RUN yarn build

FROM node:20 AS runner

WORKDIR /app
ENV NODE_ENV=production

COPY --from=builder /app/public ./public
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json

EXPOSE 3000
CMD ["yarn", "start"]