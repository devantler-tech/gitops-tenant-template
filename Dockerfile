# Placeholder Dockerfile — replace with your application's build.
#
# It must produce an image that listens on the port your deploy/ manifests
# expose (the skeleton uses 3000) and runs as a non-root user (the platform
# namespace enforces the PodSecurity "restricted" profile). A typical shape:
#
#   FROM <builder> AS build
#   WORKDIR /app
#   COPY . .
#   RUN <build your app>
#
#   FROM <runtime>
#   WORKDIR /app
#   COPY --from=build /app/dist ./
#   EXPOSE 3000
#   USER 1000
#   CMD ["<run your app>"]
FROM alpine:3.22
RUN echo "Replace this Dockerfile with your application's build."
