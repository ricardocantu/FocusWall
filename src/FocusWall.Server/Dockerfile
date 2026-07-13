# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY FocusWall.Server.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out ./
EXPOSE 5050
# Port is set explicitly in Program.cs (app.Run) — single source of truth,
# so no ASPNETCORE_URLS here.
ENTRYPOINT ["dotnet", "FocusWall.Server.dll"]
